import os
import click

from ape import project

from ape.cli import ConnectedProviderCommand, account_option

# SOME_ENV_VAR = os.getenv('SOME_ENV_VAR')

@click.group()
def cli():
    pass

@click.command(cls=ConnectedProviderCommand)
@account_option()
def info(ecosystem, provider, account, network):
    click.echo(f"ecosystem: {ecosystem.name}")
    click.echo(f"network: {network.name}")
    click.echo(f"provider_id: {provider.chain_id}")
    click.echo(f"connected: {provider.is_connected}")
    click.echo(f"account: {account}")


@click.command(cls=ConnectedProviderCommand)
@account_option()
def deploy(network, provider, account):
    pools = ["0x186cF879186986A20aADFb7eAD50e3C20cb26CeC","0x82670f35306253222F8a165869B28c64739ac62e"]
    borrowed_ixs = [0, 0]
    collateral_ixs = [1, 1]
    agg = "0x44a4FdFb626Ce98e36396d491833606309520330"

    deploy = account.deploy(project.CryptoFromPoolsRateArbitrumWAgg, pools, borrowed_ixs, collateral_ixs, agg,  max_priority_fee="1000 wei", max_fee="0.1 gwei", gas_limit="6000000")

cli.add_command(info)
cli.add_command(deploy)