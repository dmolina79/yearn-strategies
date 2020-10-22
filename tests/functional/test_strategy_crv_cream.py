import pytest
import brownie

from brownie import Wei, convert, accounts

from brownie import StrategyCreamCRV

MAX_LIMIT = 2 ** 256 - 1

# CRV
TOKEN_CONTRACT = "0xD533a949740bb3306d119CC777fa900bA034cd52"
CTOKEN_CONTRACT = "0xc7Fd8Dcee4697ceef5a2fd4608a7BD6A94C77480"

CRV_HOLDER = "0x3f5CE5FBFe3E9af3971dD833D26bA9b5C936f0bE"

STRAT_NAME = "StrategyCreamCRV"


@pytest.fixture
def token(Contract):
    yield Contract.from_explorer(TOKEN_CONTRACT)


@pytest.fixture
def cToken(Contract):
    yield Contract.from_explorer(CTOKEN_CONTRACT)


@pytest.fixture
def strategy(gov, strategist, keeper, token, vault, TestStrategy):
    strategy = strategist.deploy(StrategyCreamCRV, vault)
    strategy.setKeeper(keeper, {"from": strategist})
    vault.addStrategy(
        strategy,
        token.balanceOf(vault),  # Go up to 100% of Vault AUM
        token.balanceOf(vault),  # 100% of Vault AUM per block (no rate limit)
        50,  # 0.5% performance fee for Strategist
        {"from": gov},
    )
    yield strategy


@pytest.fixture
def vault(gov, guardian, token, rewards, Vault):
    # Deploy the Vault without any name/symbol overrides
    vault = guardian.deploy(Vault, token, gov, rewards, "", "")
    # Make it so vault has some AUM to start
    token.approve(vault, token.balanceOf(gov) // 2, {"from": gov})
    vault.deposit(token.balanceOf(gov) // 2, {"from": gov})
    assert token.balanceOf(vault) == token.balanceOf(gov)
    assert vault.totalDebt() == 0  # No connected strategies yet
    yield vault


def test_vault_deposit(strategy, vault, token, cToken, gov, fn_isolation):
    # setup accounts
    crv_holder = accounts.at(CRV_HOLDER, force=True)
    user = accounts[7]
    # fund user wallet with CRV
    token.approve(crv_holder, Wei("1000000 ether"), {"from": crv_holder})
    token.transferFrom(crv_holder, user, Wei("1000000 ether"), {"from": crv_holder})
    token.approve(vault, Wei("1000000 ether"), {"from": user})
    userBalance = token.balanceOf(user)

    # execute and expectations
    vault.deposit(userBalance // 2, {"from": user})
    assert vault.balanceOf(user) == userBalance // 2
    assert cToken.balanceOf(strategy) == 0
    assert token.balanceOf(vault) == userBalance // 2
    assert vault.totalDebt() == 0
    assert vault.pricePerShare() == 10 ** token.decimals()  # 1:1 price


def test_vault_withdraw(strategy, vault, token, cToken, gov, fn_isolation):
    # setup accounts
    crv_holder = accounts.at(CRV_HOLDER, force=True)
    user = accounts[7]
    # fund user wallet with CRV
    token.approve(crv_holder, Wei("1000000 ether"), {"from": crv_holder})
    token.transferFrom(crv_holder, user, Wei("1000000 ether"), {"from": crv_holder})
    token.approve(vault, Wei("1000000 ether"), {"from": user})
    userBalance = token.balanceOf(user)

    # execute and expectations
    vault.deposit(userBalance // 2, {"from": user})
    # Can't withdraw more shares than we have
    with brownie.reverts():
        vault.withdraw(2 * vault.balanceOf(user), {"from": user})

    vault.withdraw(vault.balanceOf(user), {"from": user})
    assert vault.totalSupply() == token.balanceOf(vault) == 0
    assert vault.totalDebt() == 0
    assert token.balanceOf(user) == userBalance


def test_strategy(
    accounts, token, cToken, vault, chain, gov, history, strategy, fn_isolation
):
    user = accounts[7]
    crv_holder = accounts.at(CRV_HOLDER, force=True)
    whale = crv_holder
    ychad = gov
    # fund user wallet
    token.approve(crv_holder, Wei("1000000 ether"), {"from": crv_holder})
    token.transferFrom(crv_holder, user, Wei("1000000 ether"), {"from": crv_holder})
    token.approve(vault, Wei("1000000 ether"), {"from": user})
    userBalance = token.balanceOf(user)

    # deposit into vault
    vault.deposit(userBalance // 2, {"from": user})

    print("crv in vault:", token.balanceOf(vault).to("ether"))
    amount = Wei("1000 ether")
    # user_before = token.balanceOf(whale)
    token.approve(vault, amount, {"from": whale})
    print("deposit amount:", amount.to("ether"))
    vault.deposit(amount, {"from": whale})

    print("deposit funds into new strategy")
    print("\nharvest")
    before = strategy.estimatedTotalAssets()
    blocks_per_year = 2_300_000
    sample = 100
    chain.mine(sample)
    print("credit available for strat", vault.creditAvailable(strategy).to("ether"))
    assert vault.creditAvailable(strategy).to("ether") > 0
    # Gas cost doesn't matter for this strat
    assert strategy.harvestTrigger(0) == True
    strategy.harvest()
    print("balance of strategy:", strategy.estimatedTotalAssets().to("ether"))
    after = strategy.estimatedTotalAssets()
    assert strategy.balanceC() == cToken.balanceOf(strategy)
    assert after >= before
    assert vault.getPricePerFullShare() > 1
    print("balance increase:", (after - before).to("ether"))
    print(f"implied apr: {(after / before - 1) * (blocks_per_year / sample):.8%}")

    # vault.withdraw(vault.balance(whale), {"from": whale})
    # user_after = token.balanceOf(whale)
    # print(f"\nuser balance increase:", (user_after - user_before).to("ether"))
    # assert user_after >= user_before


def max_approve(token, address, from_account):
    token.approve(address, MAX_LIMIT, {"from": from_account})
