/*
 * @file Tests how setting a managementFee affects a fund
 *
 * @test The rewardManagementFee function distributes management fee shares to the manager
 * @test The triggerRewardAllFees function distributes all fee shares to the manager
 * @test An investor can still redeem their shares for the expected value
 */

import { BN, toWei } from 'web3-utils';
import { call, send } from '~/utils/deploy-contract';
import { BNExpMul } from '~/utils/BNmath';
import { CONTRACT_NAMES } from '~/utils/constants';
import { setupFundWithParams } from '~/utils/fund';
import { delay } from '~/utils/time';
import { getDeployed } from '~/utils/getDeployed';
import mainnetAddrs from '~/config';

const yearInSeconds = new BN(31536000);
let deployer, manager, investor;
let defaultTxOpts, managerTxOpts, investorTxOpts;
let managementFeeRate;
let managementFee, mln, weth, fund;

beforeAll(async () => {
  [deployer, manager, investor] = await web3.eth.getAccounts();
  defaultTxOpts = { from: deployer, gas: 8000000 };
  managerTxOpts = { ...defaultTxOpts, from: manager };
  investorTxOpts = { ...defaultTxOpts, from: investor };

  mln = getDeployed(CONTRACT_NAMES.ERC20_WITH_FIELDS, mainnetAddrs.tokens.MLN);
  weth = getDeployed(CONTRACT_NAMES.WETH, mainnetAddrs.tokens.WETH);
  managementFee = getDeployed(CONTRACT_NAMES.MANAGEMENT_FEE);
  const fundFactory = getDeployed(CONTRACT_NAMES.FUND_FACTORY);

  const managementFeePeriod = 0;
  managementFeeRate = toWei('0.02', 'ether');

  fund = await setupFundWithParams({
    fees: {
      addresses: [managementFee.options.address],
      rates: [managementFeeRate],
      periods: [managementFeePeriod],
    },
    initialInvestment: {
      contribAmount: toWei('1', 'ether'),
      investor,
      tokenContract: weth
    },
    manager,
    quoteToken: weth.options.address,
    fundFactory
  });
});

test('executing rewardManagementFee distributes management fee shares to manager', async () => {
  const { feeManager, shares, vault } = fund;

  const fundCreationTime = new BN(
    await call(
      managementFee,
      'lastPayoutTime',
      [feeManager.options.address]
    )
  );

  const preFundBalanceOfWeth = new BN(await call(weth, 'balanceOf', [vault.options.address]));
  const preWethManager = new BN(await call(weth, 'balanceOf', [manager]));
  const preManagerShares = new BN(await call(shares, 'balanceOf', [manager]));
  const preTotalSupply = new BN(await call(shares, 'totalSupply'));
  const preFundGav = new BN(await call(shares, 'calcGav'));

  await send(feeManager, 'rewardManagementFee', [], managerTxOpts);

  const postFundBalanceOfWeth = new BN(await call(weth, 'balanceOf', [vault.options.address]));
  const postWethManager = new BN(await call(weth, 'balanceOf', [manager]));
  const postManagerShares = new BN(await call(shares, 'balanceOf', [manager]));
  const postTotalSupply = new BN(await call(shares, 'totalSupply'));
  const postFundGav = new BN(await call(shares, 'calcGav'));

  const payoutTime = new BN(
    await call(managementFee, 'lastPayoutTime', [feeManager.options.address])
  );
  const expectedPreDilutionFeeShares = BNExpMul(preTotalSupply, new BN(managementFeeRate))
    .mul(payoutTime.sub(fundCreationTime))
    .div(yearInSeconds);

  const expectedFeeShares = preTotalSupply.mul(expectedPreDilutionFeeShares)
    .div(preTotalSupply.sub(expectedPreDilutionFeeShares));

  const fundBalanceOfWethDiff = preFundBalanceOfWeth.sub(postFundBalanceOfWeth);
  
  expect(fundBalanceOfWethDiff).bigNumberEq(new BN(0));
  expect(postManagerShares).not.bigNumberEq(preManagerShares);
  expect(postManagerShares).bigNumberEq(preManagerShares.add(expectedFeeShares));
  expect(postTotalSupply).bigNumberEq(preTotalSupply.add(expectedFeeShares));
  expect(postFundGav).bigNumberEq(preFundGav);
  expect(postWethManager).bigNumberEq(preWethManager);
});

test('executing rewardAllFees distributes fee shares to manager', async () => {
  const { feeManager, shares, vault } = fund;

  const lastFeeConversion = new BN(
    await call(managementFee, 'lastPayoutTime', [feeManager.options.address])
  );
  const preFundBalanceOfWeth = new BN(await call(weth, 'balanceOf', [vault.options.address]));
  const preWethManager = new BN(await call(weth, 'balanceOf', [manager]));
  const preManagerShares = new BN(await call(shares, 'balanceOf', [manager]));
  const preTotalSupply = new BN(await call(shares, 'totalSupply'));
  const preFundGav = new BN(await call(shares, 'calcGav'));

  await send(feeManager, 'rewardAllFees', [], managerTxOpts);

  const postFundBalanceOfWeth = new BN(await call(weth, 'balanceOf', [vault.options.address]));
  const postWethManager = new BN(await call(weth, 'balanceOf', [manager]));
  const postManagerShares = new BN(await call(shares, 'balanceOf', [manager]));
  const postTotalSupply = new BN(await call(shares, 'totalSupply'));
  const postFundGav = new BN(await call(shares, 'calcGav'));

  const payoutTime = new BN(
    await call(managementFee, 'lastPayoutTime', [feeManager.options.address])
  );

  const expectedPreDilutionFeeShares = BNExpMul(preTotalSupply, new BN(managementFeeRate))
    .mul(payoutTime.sub(lastFeeConversion))
    .div(yearInSeconds);
  const expectedFeeShares = preTotalSupply.mul(expectedPreDilutionFeeShares)
    .div(preTotalSupply.sub(expectedPreDilutionFeeShares));

  const fundBalanceOfWethDiff = preFundBalanceOfWeth.sub(postFundBalanceOfWeth);

  expect(fundBalanceOfWethDiff).bigNumberEq(new BN(0));
  expect(postManagerShares).bigNumberEq(preManagerShares.add(expectedFeeShares));
  expect(postTotalSupply).bigNumberEq(preTotalSupply.add(expectedFeeShares));
  expect(postFundGav).bigNumberEq(preFundGav);
  expect(postWethManager).bigNumberEq(preWethManager);
});

test('Investor redeems his shares', async () => {
  const { feeManager, shares, vault } = fund;

  const lastFeeConversion = new BN(
    await call(managementFee, 'lastPayoutTime', [feeManager.options.address])
  );

  const preFundBalanceOfWeth = new BN(await call(weth, 'balanceOf', [vault.options.address]));
  const preWethInvestor = new BN(await call(weth, 'balanceOf', [investor]));
  const preTotalSupply = new BN(await call(shares, 'totalSupply'));
  const preInvestorShares = new BN(await call(shares, 'balanceOf', [investor]));

  await send(shares, 'redeemShares', [], investorTxOpts);

  const postFundBalanceOfWeth = new BN(await call(weth, 'balanceOf', [vault.options.address]));
  const postWethInvestor = new BN(await call(weth, 'balanceOf', [investor]));
  const postTotalSupply = new BN(await call(shares, 'totalSupply'));
  const postFundGav = new BN(await call(shares, 'calcGav'));

  const payoutTime = new BN(
    await call(managementFee, 'lastPayoutTime', [feeManager.options.address])
  );

  const expectedPreDilutionFeeShares = BNExpMul(preTotalSupply, new BN(managementFeeRate))
    .mul(payoutTime.sub(lastFeeConversion))
    .div(yearInSeconds);
  const expectedFeeShares = preTotalSupply.mul(expectedPreDilutionFeeShares)
    .div(preTotalSupply.sub(expectedPreDilutionFeeShares));

  const fundBalanceOfWethDiff = preFundBalanceOfWeth.sub(postFundBalanceOfWeth);

  expect(fundBalanceOfWethDiff).bigNumberEq(postWethInvestor.sub(preWethInvestor));
  expect(postTotalSupply).bigNumberEq(
    preTotalSupply.sub(preInvestorShares).add(expectedFeeShares)
  );
  expect(postWethInvestor).bigNumberEq(
    preFundBalanceOfWeth.mul(preInvestorShares)
      .div(preTotalSupply.add(expectedFeeShares))
      .add(preWethInvestor)
  );
  expect(postFundGav).bigNumberEq(postFundBalanceOfWeth);
});

test('Manager redeems his shares', async () => {
  const { shares } = fund;

  const preManagerShares = new BN(await call(shares, 'balanceOf', [manager]));
  expect(preManagerShares).not.bigNumberEq(new BN(0));

  await send(shares, 'redeemShares', [], managerTxOpts);

  const postManagerShares = new BN(await call(shares, 'balanceOf', [manager]));
  expect(postManagerShares).bigNumberEq(new BN(0));
});
