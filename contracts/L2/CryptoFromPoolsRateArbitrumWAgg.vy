# @version 0.4.0
#pragma optimize gas
#pragma evm-version shanghai
"""
@title CryptoFromPoolsRateWAgg
@notice Price oracle for pools which contain cryptos and crvUSD. It also uses aggregator to measure /USD instead of /crvUSD price.
        The oracle chains multiple pool oracles, and at the same time applies rate oracles if they are applicable
@author Curve.Fi
@license MIT
"""

MAX_COINS: constant(uint256) = 8
MAX_POOLS: constant(uint256) = 8


interface Pool:
    def price_oracle(i: uint256 = 0) -> uint256: view  # Universal method!
    def coins(i: uint256) -> address: view
    def stored_rates() -> DynArray[uint256, MAX_COINS]: view

interface StableAggregator:
    def price() -> uint256: view
    def price_w() -> uint256: nonpayable
    def stablecoin() -> address: view

interface ChainlinkOracle:
    def latestRoundData() -> ChainlinkAnswer: view

struct ChainlinkAnswer:
    roundID: uint80
    answer: int256
    startedAt: uint256
    updatedAt: uint256
    answeredInRound: uint80


POOLS: public(immutable(DynArray[Pool, MAX_POOLS]))
BORROWED_IX: public(immutable(DynArray[uint256, MAX_POOLS]))
COLLATERAL_IX: public(immutable(DynArray[uint256, MAX_POOLS]))
NO_ARGUMENT: public(immutable(DynArray[bool, MAX_POOLS]))
POOL_COUNT: public(immutable(uint256))
USE_RATES: public(immutable(DynArray[bool, MAX_POOLS]))
AGG: public(immutable(StableAggregator))

RATE_MAX_SPEED: constant(uint256) = 10**16 // 60  # Max speed of Rate change

CHAINLINK_UPTIME_FEED: public(constant(address)) = 0xFdB631F5EE196F0ed6FAa767959853A9F217697D
DOWNTIME_WAIT: public(constant(uint256)) = 3988  # 866 * log(100) s

cached_timestamp: public(uint256)
cached_rate: public(uint256)

@deploy
def __init__(
        pools: DynArray[Pool, MAX_POOLS],
        borrowed_ixs: DynArray[uint256, MAX_POOLS],
        collateral_ixs: DynArray[uint256, MAX_POOLS],
        agg: StableAggregator
    ):
    POOLS = pools
    pool_count: uint256 = 0
    no_arguments: DynArray[bool, MAX_POOLS] = empty(DynArray[bool, MAX_POOLS])
    use_rates: DynArray[bool, MAX_POOLS] = empty(DynArray[bool, MAX_POOLS])
    AGG = agg

    for i: uint256 in range(MAX_POOLS):
        if i == len(pools):
            assert i != 0, "Wrong pool counts"
            pool_count = i
            break

        # Find N
        N: uint256 = 0
        for j: uint256 in range(MAX_COINS + 1):
            success: bool = False
            res: Bytes[32] = empty(Bytes[32])
            success, res = raw_call(
                pools[i].address,
                abi_encode(j, method_id=method_id("coins(uint256)")),
                max_outsize=32, is_static_call=True, revert_on_failure=False)
            if not success:
                assert j != 0, "No coins(0)"
                N = j
                break

        assert borrowed_ixs[i] != collateral_ixs[i]
        assert borrowed_ixs[i] < N
        assert collateral_ixs[i] < N

        # Init variables for raw call
        success: bool = False

        # Check and record if pool requires coin id in argument or no
        if N == 2:
            res: Bytes[32] = empty(Bytes[32])
            success, res = raw_call(
                pools[i].address,
                abi_encode(empty(uint256), method_id=method_id("price_oracle(uint256)")),
                max_outsize=32, is_static_call=True, revert_on_failure=False)
            if not success:
                no_arguments.append(True)
            else:
                no_arguments.append(False)
        else:
            no_arguments.append(False)

        res: Bytes[1024] = empty(Bytes[1024])
        success, res = raw_call(pools[i].address, method_id("stored_rates()"), max_outsize=1024, is_static_call=True, revert_on_failure=False)
        stored_rates: DynArray[uint256, MAX_COINS] = empty(DynArray[uint256, MAX_COINS])
        if success and len(res) > 0:
            stored_rates = abi_decode(res, DynArray[uint256, MAX_COINS])

        u: bool = False
        for r: uint256 in stored_rates:
            if r != 10**18:
                u = True
        use_rates.append(u)

    NO_ARGUMENT = no_arguments
    BORROWED_IX = borrowed_ixs
    COLLATERAL_IX = collateral_ixs
    if pool_count == 0:
        pool_count = MAX_POOLS
    POOL_COUNT = pool_count
    USE_RATES = use_rates


@internal
@view
def _raw_stored_rate() -> (uint256, bool):
    rate: uint256 = 10**18
    use_rates: bool = False

    for i: uint256 in range(MAX_POOLS):
        if i == POOL_COUNT:
            break
        if USE_RATES[i]:
            use_rates = True
            rates: DynArray[uint256, MAX_COINS] = staticcall POOLS[i].stored_rates()
            rate = rate * rates[COLLATERAL_IX[i]] // rates[BORROWED_IX[i]]

    return rate, use_rates


@internal
@view
def _stored_rate() -> (uint256, bool):
    use_rates: bool = False
    rate: uint256 = 0
    rate, use_rates = self._raw_stored_rate()
    if not use_rates:
        return rate, use_rates

    cached_rate: uint256 = self.cached_rate

    if cached_rate == 0 or cached_rate == rate:
        return rate, use_rates

    if rate > cached_rate:
        return min(rate, cached_rate * (10**18 + RATE_MAX_SPEED * (block.timestamp - self.cached_timestamp)) // 10**18), use_rates

    else:
        return max(rate, cached_rate * (10**18 - min(RATE_MAX_SPEED * (block.timestamp - self.cached_timestamp), 10**18)) // 10**18), use_rates


@external
@view
def stored_rate() -> uint256:
    return self._stored_rate()[0]


@internal
def _stored_rate_w() -> uint256:
    rate: uint256 = 0
    use_rates: bool = False
    rate, use_rates = self._stored_rate()
    if use_rates:
        self.cached_rate = rate
        self.cached_timestamp = block.timestamp
    return rate


@internal
@view
def _unscaled_price() -> uint256:
    # Check that we had no downtime
    cl_answer: ChainlinkAnswer = staticcall ChainlinkOracle(CHAINLINK_UPTIME_FEED).latestRoundData()
    assert cl_answer.answer == 0, "Sequencer is down"
    assert block.timestamp >= cl_answer.startedAt + DOWNTIME_WAIT, "Wait after downtime"

    _price: uint256 = 10**18
    for i: uint256 in range(MAX_POOLS):
        if i >= POOL_COUNT:
            break
        p_borrowed: uint256 = 10**18
        p_collateral: uint256 = 10**18

        if NO_ARGUMENT[i]:
            p: uint256 = staticcall POOLS[i].price_oracle()
            if COLLATERAL_IX[i] > 0:
                p_collateral = p
            else:
                p_borrowed = p

        else:
            if BORROWED_IX[i] > 0:
                p_borrowed = staticcall POOLS[i].price_oracle(unsafe_sub(BORROWED_IX[i], 1))
            if COLLATERAL_IX[i] > 0:
                p_collateral = staticcall POOLS[i].price_oracle(unsafe_sub(COLLATERAL_IX[i], 1))
        _price = _price * p_collateral // p_borrowed
    return _price


@external
@view
def price() -> uint256:
    return self._unscaled_price() * self._stored_rate()[0] // 10**18 * staticcall AGG.price() // 10**18


@external
def price_w() -> uint256:
    return self._unscaled_price() * self._stored_rate_w() // 10**18 * extcall AGG.price_w() // 10**18
