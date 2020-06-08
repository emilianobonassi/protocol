/*
 * @file Unit tests for vault via the ZeroExV3Adapter
 *
 * @test takeOrder: __validateTakeOrderParams
 * @test takeOrder: Order 1: full amount w/ protocolFee
 * @test takeOrder: Order 2: full amount w/ protocolFee, w/ WETH takerFee
 * @test takeOrder: Order: full amount w/ protocolFee, w/ MLN takerFee
 * TODO: takeOrder: Order: full amount w/ protocolFee, w/ DAI takerFee
 * TODO: takeOrder: Order: full amount w/ no fees
 * TODO: takeOrder: Order: partial amount w/ takerFee and protocolFee
 */

import { assetDataUtils } from '@0x/order-utils';
import { BN, toWei, randomHex } from 'web3-utils';
import { call, send } from '~/deploy/utils/deploy-contract';
import { CONTRACT_NAMES, EMPTY_ADDRESS } from '~/tests/utils/constants';
import { investInFund, setupFundWithParams } from '~/tests/utils/fund';
import {
  getEventCountFromLogs,
  getEventFromLogs,
  getFunctionSignature
} from '~/tests/utils/metadata';
import {
  createUnsignedZeroExOrder,
  encodeZeroExTakeOrderArgs,
  signZeroExOrder
} from '~/tests/utils/zeroExV3';
import { getDeployed } from '~/tests/utils/getDeployed';
import * as mainnetAddrs from '~/mainnet_thirdparty_contracts';

let web3;
let deployer, manager;
let defaultTxOpts, managerTxOpts, governorTxOpts;
let zrx, mln, weth;
let priceSource;
let erc20Proxy, zeroExAdapter, zeroExExchange;
let fund, fundFactory;
let takeOrderSignature;
let defaultProtocolFeeMultiplier, protocolFeeAmount, chainId;

beforeAll(async () => {
  // @dev Set gas price explicitly for consistently calculating 0x v3's protocol fee
  const gasPrice = toWei('2', 'gwei');
  web3 = await startChain();
  [deployer, manager] = await web3.eth.getAccounts();
  defaultTxOpts = { from: deployer, gas: 8000000, gasPrice };
  managerTxOpts = { from: manager, gas: 8000000, gasPrice };
  governorTxOpts = { from: mainnetAddrs.zeroExV3.ZeroExGovernor, gas: 8000000 };

  // load governor with eth so it can send tx
  await web3.eth.sendTransaction({
    from: deployer,
    to: mainnetAddrs.zeroExV3.ZeroExGovernor,
    value: toWei('1', 'ether'),
    gas: 1000000
  });

  takeOrderSignature = getFunctionSignature(
    CONTRACT_NAMES.ORDER_TAKER,
    'takeOrder',
  );

  mln = getDeployed(CONTRACT_NAMES.MLN, web3, mainnetAddrs.tokens.MLN);
  weth = getDeployed(CONTRACT_NAMES.WETH, web3, mainnetAddrs.tokens.WETH);
  zrx = getDeployed(CONTRACT_NAMES.ZRX, web3, mainnetAddrs.tokens.ZRX);
  priceSource = getDeployed(CONTRACT_NAMES.KYBER_PRICEFEED, web3);
  erc20Proxy = getDeployed(CONTRACT_NAMES.ZERO_EX_V2_ERC20_PROXY, web3, mainnetAddrs.zeroExV3.ZeroExV3ERC20Proxy);
  zeroExAdapter = getDeployed(CONTRACT_NAMES.ZERO_EX_V3_ADAPTER, web3);
  zeroExExchange = getDeployed(CONTRACT_NAMES.ZERO_EX_V3_EXCHANGE, web3, mainnetAddrs.zeroExV3.ZeroExV3Exchange);
  fundFactory = getDeployed(CONTRACT_NAMES.FUND_FACTORY, web3);

  defaultProtocolFeeMultiplier = await call(zeroExExchange, 'protocolFeeMultiplier');
  protocolFeeAmount = new BN(defaultProtocolFeeMultiplier).mul(new BN(gasPrice));
  chainId = await web3.eth.net.getId();
});

describe('takeOrder', () => {
  // @dev Only need to run this once
  describe('__validateTakeOrderParams', () => {
    let signedOrder;
    let makerTokenAddress, takerTokenAddress, fillQuantity, takerFeeTokenAddress;
    let badTokenAddress;

    beforeAll(async () => {
      fund = await setupFundWithParams({
        defaultTokens: [mln.options.address, weth.options.address],
        integrationAdapters: [zeroExAdapter.options.address],
        quoteToken: weth.options.address,
        fundFactory,
        manager,
        web3
      });
    });

    test('third party makes and validates an off-chain order', async () => {
      const makerAddress = deployer;
      const makerAssetAmount = toWei('1', 'Ether');
      const takerAssetAmount = toWei('0.05', 'Ether');
      const feeRecipientAddress = randomHex(20);
      const takerFee = toWei('0.001', 'ether');
      makerTokenAddress = mln.options.address;
      takerTokenAddress = weth.options.address;
      fillQuantity = takerAssetAmount;
      takerFeeTokenAddress = weth.options.address;
      badTokenAddress = zrx.options.address;

      const unsignedOrder = await createUnsignedZeroExOrder(
        zeroExExchange.options.address,
        chainId,
        {
          makerAddress,
          makerTokenAddress,
          makerAssetAmount,
          takerTokenAddress,
          takerAssetAmount,
          feeRecipientAddress,
          takerFee,
          takerFeeTokenAddress
        },
      );

      await send(mln, 'approve', [erc20Proxy.options.address, makerAssetAmount], defaultTxOpts, web3);
      signedOrder = await signZeroExOrder(unsignedOrder, deployer);
      const signatureValid = await call(
        zeroExExchange,
        'isValidOrderSignature',
        [signedOrder, signedOrder.signature]
      );

      expect(signatureValid).toBeTruthy();
    });

    it('does not allow taker fill amount greater than order max', async () => {
      const { vault } = fund;
      const badFillQuantity = new BN(fillQuantity).add(new BN(1)).toString();

      const encodedArgs = encodeZeroExTakeOrderArgs(signedOrder, badFillQuantity);

      await expect(
        send(
          vault,
          'callOnIntegration',
          [
            zeroExAdapter.options.address,
            takeOrderSignature,
            encodedArgs,
          ],
          managerTxOpts,
          web3
        )
      ).rejects.toThrowFlexible("taker fill amount greater than max order quantity");
    });
  });

  describe('Fill Order 1: Full taker amount w/ protocol fee, w/o taker fee', () => {
    let signedOrder;
    let makerTokenAddress, takerTokenAddress, fillQuantity;
    let preFundHoldingsMln, preFundHoldingsWeth, postFundHoldingsMln, postFundHoldingsWeth;
    let tx;

    beforeAll(async () => {
      fund = await setupFundWithParams({
        defaultTokens: [mln.options.address, weth.options.address],
        integrationAdapters: [zeroExAdapter.options.address],
        initialInvestment: {
          contribAmount: toWei('1', 'ether'),
          investor: deployer,
          tokenContract: weth
        },
        quoteToken: weth.options.address,
        fundFactory,
        manager,
        web3
      });
    });

    test('third party makes and validates an off-chain order', async () => {
      const makerAddress = deployer;
      const makerAssetAmount = toWei('1', 'Ether');
      const takerAssetAmount = toWei('0.05', 'Ether');
      makerTokenAddress = mln.options.address;
      takerTokenAddress = weth.options.address;
      fillQuantity = takerAssetAmount;

      const unsignedOrder = await createUnsignedZeroExOrder(
        zeroExExchange.options.address,
        chainId,
        {
          makerAddress,
          makerTokenAddress,
          makerAssetAmount,
          takerTokenAddress,
          takerAssetAmount,
        },
      );

      await send(mln, 'approve', [erc20Proxy.options.address, makerAssetAmount], defaultTxOpts, web3);
      signedOrder = await signZeroExOrder(unsignedOrder, deployer);
      const signatureValid = await call(
        zeroExExchange,
        'isValidOrderSignature',
        [signedOrder, signedOrder.signature]
      );

      expect(signatureValid).toBeTruthy();
    });

    test('order is filled through the fund', async () => {
      const { vault } = fund;

      const makerFeeAsset = signedOrder.makerFeeAssetData === '0x' ?
        EMPTY_ADDRESS :
        assetDataUtils.decodeERC20AssetData(signedOrder.makerFeeAssetData).tokenAddress;
      const takerFeeAsset = signedOrder.takerFeeAssetData === '0x' ?
        EMPTY_ADDRESS :
        assetDataUtils.decodeERC20AssetData(signedOrder.takerFeeAssetData).tokenAddress;

      preFundHoldingsWeth = new BN(
        await call(vault, 'assetBalances', [weth.options.address])
      );
      preFundHoldingsMln = new BN(
        await call(vault, 'assetBalances', [mln.options.address])
      );

      const encodedArgs = encodeZeroExTakeOrderArgs(signedOrder, fillQuantity);

      tx = await send(
        vault,
        'callOnIntegration',
        [
          zeroExAdapter.options.address,
          takeOrderSignature,
          encodedArgs,
        ],
        managerTxOpts,
        web3
      );

      postFundHoldingsWeth = new BN(
        await call(vault, 'assetBalances', [weth.options.address])
      );
      postFundHoldingsMln = new BN(
        await call(vault, 'assetBalances', [mln.options.address])
      );
    });

    it('correctly updates fund holdings', async () => {
      expect(postFundHoldingsWeth).bigNumberEq(
        preFundHoldingsWeth.sub(new BN(signedOrder.takerAssetAmount)).sub(protocolFeeAmount)
      );
      expect(postFundHoldingsMln).bigNumberEq(
        preFundHoldingsMln.add(new BN(signedOrder.makerAssetAmount))
      );
    });

    it('emits correct OrderFilled event', async () => {
      const orderFilledCount = getEventCountFromLogs(
        tx.logs,
        CONTRACT_NAMES.ZERO_EX_V3_ADAPTER,
        'OrderFilled'
      );
      expect(orderFilledCount).toBe(1);

      const orderFilled = getEventFromLogs(
        tx.logs,
        CONTRACT_NAMES.ZERO_EX_V3_ADAPTER,
        'OrderFilled'
      );
      expect(orderFilled.targetContract).toBe(zeroExExchange.options.address);
      expect(orderFilled.buyAsset).toBe(makerTokenAddress);
      expect(orderFilled.buyAmount).toBe(signedOrder.makerAssetAmount);
      expect(orderFilled.sellAsset).toBe(takerTokenAddress);
      expect(orderFilled.sellAmount).toBe(signedOrder.takerAssetAmount);
      expect(orderFilled.feeAssets.length).toBe(1);
      expect(orderFilled.feeAssets[0]).toBe(weth.options.address);
      expect(orderFilled.feeAmounts.length).toBe(1);
      expect(orderFilled.feeAmounts[0]).toBe(protocolFeeAmount.toString());
    });
  });

  describe('Fill Order 2: Full amount, w/ protocol fee (taker asset), w/ taker fee in weth (taker asset)', () => {
    let signedOrder;
    let makerTokenAddress, takerTokenAddress, fillQuantity;
    let preFundHoldingsMln, postFundHoldingsMln;
    let preFundHoldingsWeth, postFundHoldingsWeth;
    let tx;

    beforeAll(async () => {
      fund = await setupFundWithParams({
        defaultTokens: [mln.options.address, weth.options.address],
        integrationAdapters: [zeroExAdapter.options.address],
        initialInvestment: {
          contribAmount: toWei('1', 'ether'),
          investor: deployer,
          tokenContract: weth
        },
        quoteToken: weth.options.address,
        fundFactory,
        manager,
        web3
      });
    });

    test('third party makes and validates an off-chain order', async () => {
      const makerAddress = deployer;
      const makerAssetAmount = toWei('1', 'Ether');
      const takerAssetAmount = toWei('0.05', 'Ether');
      const feeRecipientAddress = randomHex(20);
      const takerFee = toWei('0.001', 'ether');
      const takerFeeTokenAddress = weth.options.address;
      makerTokenAddress = mln.options.address;
      takerTokenAddress = weth.options.address;
      fillQuantity = takerAssetAmount;

      const unsignedOrder = await createUnsignedZeroExOrder(
        zeroExExchange.options.address,
        chainId,
        {
          makerAddress,
          makerTokenAddress,
          makerAssetAmount,
          takerTokenAddress,
          takerAssetAmount,
          feeRecipientAddress,
          takerFee,
          takerFeeTokenAddress
        },
      );

      await send(mln, 'approve', [erc20Proxy.options.address, makerAssetAmount], defaultTxOpts, web3);
      signedOrder = await signZeroExOrder(unsignedOrder, deployer);
      const signatureValid = await call(
        zeroExExchange,
        'isValidOrderSignature',
        [signedOrder, signedOrder.signature]
      );

      expect(signatureValid).toBeTruthy();
    });

    test('order is filled through the fund', async () => {
      const { vault } = fund;

      const makerFeeAsset = signedOrder.makerFeeAssetData === '0x' ?
        EMPTY_ADDRESS :
        assetDataUtils.decodeERC20AssetData(signedOrder.makerFeeAssetData).tokenAddress;
      const takerFeeAsset = signedOrder.takerFeeAssetData === '0x' ?
        EMPTY_ADDRESS :
        assetDataUtils.decodeERC20AssetData(signedOrder.takerFeeAssetData).tokenAddress;

      preFundHoldingsWeth = new BN(
        await call(vault, 'assetBalances', [weth.options.address])
      );
      preFundHoldingsMln = new BN(
        await call(vault, 'assetBalances', [mln.options.address])
      );

      const encodedArgs = encodeZeroExTakeOrderArgs(signedOrder, fillQuantity);

      tx = await send(
        vault,
        'callOnIntegration',
        [
          zeroExAdapter.options.address,
          takeOrderSignature,
          encodedArgs,
        ],
        managerTxOpts,
        web3
      );

      postFundHoldingsWeth = new BN(
        await call(vault, 'assetBalances', [weth.options.address])
      );
      postFundHoldingsMln = new BN(
        await call(vault, 'assetBalances', [mln.options.address])
      );
    });

    it('correctly updates fund holdings', async () => {
      expect(postFundHoldingsWeth).bigNumberEq(
        preFundHoldingsWeth
          .sub(new BN(signedOrder.takerAssetAmount))
          .sub(protocolFeeAmount)
          .sub(new BN(signedOrder.takerFee))
      );
      expect(postFundHoldingsMln).bigNumberEq(
        preFundHoldingsMln.add(new BN(signedOrder.makerAssetAmount))
      );
    });

    it('emits correct OrderFilled event', async () => {
      const orderFilledCount = getEventCountFromLogs(
        tx.logs,
        CONTRACT_NAMES.ZERO_EX_V3_ADAPTER,
        'OrderFilled'
      );
      expect(orderFilledCount).toBe(1);

      const orderFilled = getEventFromLogs(
        tx.logs,
        CONTRACT_NAMES.ZERO_EX_V3_ADAPTER,
        'OrderFilled'
      );
      expect(orderFilled.targetContract).toBe(zeroExExchange.options.address);
      expect(orderFilled.buyAsset).toBe(makerTokenAddress);
      expect(orderFilled.buyAmount).toBe(signedOrder.makerAssetAmount);
      expect(orderFilled.sellAsset).toBe(takerTokenAddress);
      expect(orderFilled.sellAmount).toBe(signedOrder.takerAssetAmount);
      expect(orderFilled.feeAssets.length).toBe(1);
      expect(orderFilled.feeAssets[0]).toBe(weth.options.address);
      expect(orderFilled.feeAmounts.length).toBe(1);
      expect(new BN(orderFilled.feeAmounts[0])).bigNumberEq(
        new BN(signedOrder.takerFee).add(protocolFeeAmount)
      );
    });
  });

  describe('Fill Order 3: Full amount, w/ protocol fee (taker asset), w/ taker fee in mln (maker asset)', () => {
    let signedOrder;
    let makerTokenAddress, takerTokenAddress, takerFee, takerFeeTokenAddress, fillQuantity;
    let preFundHoldingsMln, postFundHoldingsMln;
    let preFundHoldingsWeth, postFundHoldingsWeth;
    let tx;

    beforeAll(async () => {
      fund = await setupFundWithParams({
        defaultTokens: [mln.options.address, weth.options.address],
        integrationAdapters: [zeroExAdapter.options.address],
        initialInvestment: {
          contribAmount: toWei('1', 'ether'),
          investor: deployer,
          tokenContract: weth
        },
        quoteToken: weth.options.address,
        fundFactory,
        manager,
        web3
      });

      // Make 2nd investment with MLN to allow taker fee trade
      takerFee = toWei('0.001', 'ether');
      await investInFund({
        fundAddress: fund.hub.options.address,
        investment: {
          contribAmount: takerFee,
          investor: deployer,
          tokenContract: mln
        },
        tokenPriceData: {
          priceSource,
          tokenAddresses: [
            mln.options.address
          ]
        },
        web3
      });
    });

    test('third party makes and validates an off-chain order', async () => {
      const makerAddress = deployer;
      const makerAssetAmount = toWei('1', 'Ether');
      const takerAssetAmount = toWei('0.05', 'Ether');
      const feeRecipientAddress = randomHex(20);
      takerFeeTokenAddress = mln.options.address;
      makerTokenAddress = mln.options.address;
      takerTokenAddress = weth.options.address;
      fillQuantity = takerAssetAmount;

      const unsignedOrder = await createUnsignedZeroExOrder(
        zeroExExchange.options.address,
        chainId,
        {
          makerAddress,
          makerTokenAddress,
          makerAssetAmount,
          takerTokenAddress,
          takerAssetAmount,
          feeRecipientAddress,
          takerFee,
          takerFeeTokenAddress
        },
      );

      await send(mln, 'approve', [erc20Proxy.options.address, makerAssetAmount], defaultTxOpts, web3);
      signedOrder = await signZeroExOrder(unsignedOrder, deployer);
      const signatureValid = await call(
        zeroExExchange,
        'isValidOrderSignature',
        [signedOrder, signedOrder.signature]
      );

      expect(signatureValid).toBeTruthy();
    });

    test('order is filled through the fund', async () => {
      const { vault } = fund;

      const makerFeeAsset = signedOrder.makerFeeAssetData === '0x' ?
        EMPTY_ADDRESS :
        assetDataUtils.decodeERC20AssetData(signedOrder.makerFeeAssetData).tokenAddress;
      const takerFeeAsset = signedOrder.takerFeeAssetData === '0x' ?
        EMPTY_ADDRESS :
        assetDataUtils.decodeERC20AssetData(signedOrder.takerFeeAssetData).tokenAddress;

      preFundHoldingsWeth = new BN(
        await call(vault, 'assetBalances', [weth.options.address])
      );
      preFundHoldingsMln = new BN(
        await call(vault, 'assetBalances', [mln.options.address])
      );

      const encodedArgs = encodeZeroExTakeOrderArgs(signedOrder, fillQuantity);

      tx = await send(
        vault,
        'callOnIntegration',
        [
          zeroExAdapter.options.address,
          takeOrderSignature,
          encodedArgs,
        ],
        managerTxOpts,
        web3
      );

      postFundHoldingsWeth = new BN(
        await call(vault, 'assetBalances', [weth.options.address])
      );
      postFundHoldingsMln = new BN(
        await call(vault, 'assetBalances', [mln.options.address])
      );
    });

    it('correctly updates fund holdings', async () => {
      expect(postFundHoldingsWeth).bigNumberEq(
        preFundHoldingsWeth
          .sub(new BN(signedOrder.takerAssetAmount))
          .sub(protocolFeeAmount)
      );
      expect(postFundHoldingsMln).bigNumberEq(
        preFundHoldingsMln
          .add(new BN(signedOrder.makerAssetAmount))
          .sub(new BN(signedOrder.takerFee))
      );
    });

    it('emits correct OrderFilled event', async () => {
      const orderFilledCount = getEventCountFromLogs(
        tx.logs,
        CONTRACT_NAMES.ZERO_EX_V3_ADAPTER,
        'OrderFilled'
      );
      expect(orderFilledCount).toBe(1);

      const orderFilled = getEventFromLogs(
        tx.logs,
        CONTRACT_NAMES.ZERO_EX_V3_ADAPTER,
        'OrderFilled'
      );
      expect(orderFilled.targetContract).toBe(zeroExExchange.options.address);
      expect(orderFilled.buyAsset).toBe(makerTokenAddress);
      expect(orderFilled.buyAmount).toBe(signedOrder.makerAssetAmount);
      expect(orderFilled.sellAsset).toBe(takerTokenAddress);
      expect(orderFilled.sellAmount).toBe(signedOrder.takerAssetAmount);
      expect(orderFilled.feeAssets.length).toBe(2);
      expect(orderFilled.feeAssets[0]).toBe(weth.options.address);
      expect(orderFilled.feeAssets[1]).toBe(takerFeeTokenAddress);
      expect(orderFilled.feeAmounts.length).toBe(2);
      expect(new BN(orderFilled.feeAmounts[0])).bigNumberEq(protocolFeeAmount);
      expect(orderFilled.feeAmounts[1]).toBe(signedOrder.takerFee);
    });
  });

  describe('Fill Order 4: Full amount, NO protocol fee, w/ taker fee in zrx (3rd asset)', () => {
    let signedOrder;
    let makerTokenAddress, takerTokenAddress, takerFee, takerFeeTokenAddress, fillQuantity;
    let preFundHoldingsMln, postFundHoldingsMln;
    let preFundHoldingsWeth, postFundHoldingsWeth;
    let preFundHoldingsDai, postFundHoldingsDai;
    let tx;

    beforeAll(async () => {
      fund = await setupFundWithParams({
        defaultTokens: [mln.options.address, weth.options.address],
        integrationAdapters: [zeroExAdapter.options.address],
        initialInvestment: {
          contribAmount: toWei('1', 'ether'),
          investor: deployer,
          tokenContract: weth
        },
        quoteToken: weth.options.address,
        fundFactory,
        manager,
        web3
      });

      // Make 2nd investment with DAI to allow taker fee trade
      takerFee = toWei('1', 'ether');
      await send(
        fund.shares,
        'enableSharesInvestmentAssets',
        [[zrx.options.address]],
        managerTxOpts,
        web3
      );
      await investInFund({
        fundAddress: fund.hub.options.address,
        investment: {
          contribAmount: takerFee,
          investor: deployer,
          tokenContract: zrx
        },
        tokenPriceData: {
          priceSource,
          tokenAddresses: [
            zrx.options.address
          ]
        },
        web3
      });
      console.log('after invest')

      // Set protocolFeeMultiplier to 0
      await send(
        zeroExExchange,
        'setProtocolFeeMultiplier',
        [0],
        governorTxOpts,
        web3
      );
      console.log('after setmult')
    });

    afterAll(async () => {
      // Reset protocolFeeMultiplier to default
      await send(
        zeroExExchange,
        'setProtocolFeeMultiplier',
        [defaultProtocolFeeMultiplier],
        governorTxOpts,
        web3
      );
    });

    test('third party makes and validates an off-chain order', async () => {
      const makerAddress = deployer;
      const makerAssetAmount = toWei('1', 'Ether');
      const takerAssetAmount = toWei('0.05', 'Ether');
      const feeRecipientAddress = randomHex(20);
      takerFeeTokenAddress = zrx.options.address;
      makerTokenAddress = mln.options.address;
      takerTokenAddress = weth.options.address;
      fillQuantity = takerAssetAmount;

      const unsignedOrder = await createUnsignedZeroExOrder(
        zeroExExchange.options.address,
        chainId,
        {
          makerAddress,
          makerTokenAddress,
          makerAssetAmount,
          takerTokenAddress,
          takerAssetAmount,
          feeRecipientAddress,
          takerFee,
          takerFeeTokenAddress
        },
      );

      await send(mln, 'approve', [erc20Proxy.options.address, makerAssetAmount], defaultTxOpts, web3);
      signedOrder = await signZeroExOrder(unsignedOrder, deployer);
      const signatureValid = await call(
        zeroExExchange,
        'isValidOrderSignature',
        [signedOrder, signedOrder.signature]
      );

      expect(signatureValid).toBeTruthy();
    });

    test('order is filled through the fund', async () => {
      const { vault } = fund;

      const makerFeeAsset = signedOrder.makerFeeAssetData === '0x' ?
        EMPTY_ADDRESS :
        assetDataUtils.decodeERC20AssetData(signedOrder.makerFeeAssetData).tokenAddress;
      const takerFeeAsset = signedOrder.takerFeeAssetData === '0x' ?
        EMPTY_ADDRESS :
        assetDataUtils.decodeERC20AssetData(signedOrder.takerFeeAssetData).tokenAddress;

      preFundHoldingsWeth = new BN(
        await call(vault, 'assetBalances', [weth.options.address])
      );
      preFundHoldingsMln = new BN(
        await call(vault, 'assetBalances', [mln.options.address])
      );
      preFundHoldingsDai = new BN(
        await call(vault, 'assetBalances', [zrx.options.address])
      );

      const encodedArgs = encodeZeroExTakeOrderArgs(signedOrder, fillQuantity);

      tx = await send(
        vault,
        'callOnIntegration',
        [
          zeroExAdapter.options.address,
          takeOrderSignature,
          encodedArgs,
        ],
        managerTxOpts,
        web3
      );

      postFundHoldingsWeth = new BN(
        await call(vault, 'assetBalances', [weth.options.address])
      );
      postFundHoldingsMln = new BN(
        await call(vault, 'assetBalances', [mln.options.address])
      );
      postFundHoldingsDai = new BN(
        await call(vault, 'assetBalances', [zrx.options.address])
      );
    });

    it('correctly updates fund holdings', async () => {
      expect(postFundHoldingsWeth).bigNumberEq(
        preFundHoldingsWeth.sub(new BN(signedOrder.takerAssetAmount))
      );
      expect(postFundHoldingsMln).bigNumberEq(
        preFundHoldingsMln.add(new BN(signedOrder.makerAssetAmount))
      );
      expect(postFundHoldingsDai).bigNumberEq(
        preFundHoldingsDai.sub(new BN(signedOrder.takerFee))
      );
    });

    it('emits correct OrderFilled event', async () => {
      const orderFilledCount = getEventCountFromLogs(
        tx.logs,
        CONTRACT_NAMES.ZERO_EX_V3_ADAPTER,
        'OrderFilled'
      );
      expect(orderFilledCount).toBe(1);

      const orderFilled = getEventFromLogs(
        tx.logs,
        CONTRACT_NAMES.ZERO_EX_V3_ADAPTER,
        'OrderFilled'
      );
      expect(orderFilled.targetContract).toBe(zeroExExchange.options.address);
      expect(orderFilled.buyAsset).toBe(makerTokenAddress);
      expect(orderFilled.buyAmount).toBe(signedOrder.makerAssetAmount);
      expect(orderFilled.sellAsset).toBe(takerTokenAddress);
      expect(orderFilled.sellAmount).toBe(signedOrder.takerAssetAmount);
      expect(orderFilled.feeAssets.length).toBe(1);
      expect(orderFilled.feeAssets[0]).toBe(takerFeeTokenAddress);
      expect(orderFilled.feeAmounts.length).toBe(1);
      expect(orderFilled.feeAmounts[0]).toBe(signedOrder.takerFee);
    });
  });

  describe('Fill Order 5: Full amount, NO protocol fee', () => {
    let signedOrder;
    let makerTokenAddress, takerTokenAddress, fillQuantity;
    let preFundHoldingsMln, postFundHoldingsMln;
    let preFundHoldingsWeth, postFundHoldingsWeth;
    let tx;

    beforeAll(async () => {
      fund = await setupFundWithParams({
        defaultTokens: [mln.options.address, weth.options.address],
        integrationAdapters: [zeroExAdapter.options.address],
        initialInvestment: {
          contribAmount: toWei('1', 'ether'),
          investor: deployer,
          tokenContract: weth
        },
        quoteToken: weth.options.address,
        fundFactory,
        manager,
        web3
      });

      // Set protocolFeeMultiplier to 0
      await send(zeroExExchange, 'setProtocolFeeMultiplier', [0], governorTxOpts, web3);
    });

    afterAll(async () => {
      // Reset protocolFeeMultiplier to default
      await send(
        zeroExExchange,
        'setProtocolFeeMultiplier',
        [defaultProtocolFeeMultiplier],
        governorTxOpts,
        web3
      );
    });

    test('third party makes and validates an off-chain order', async () => {
      const makerAddress = deployer;
      const makerAssetAmount = toWei('1', 'Ether');
      const takerAssetAmount = toWei('0.05', 'Ether');
      makerTokenAddress = mln.options.address;
      takerTokenAddress = weth.options.address;
      fillQuantity = takerAssetAmount;

      const unsignedOrder = await createUnsignedZeroExOrder(
        zeroExExchange.options.address,
        chainId,
        {
          makerAddress,
          makerTokenAddress,
          makerAssetAmount,
          takerTokenAddress,
          takerAssetAmount
        },
      );

      await send(mln, 'approve', [erc20Proxy.options.address, makerAssetAmount], defaultTxOpts, web3);
      signedOrder = await signZeroExOrder(unsignedOrder, deployer);
      const signatureValid = await call(
        zeroExExchange,
        'isValidOrderSignature',
        [signedOrder, signedOrder.signature]
      );

      expect(signatureValid).toBeTruthy();
    });

    test('order is filled through the fund', async () => {
      const { vault } = fund;

      const makerFeeAsset = signedOrder.makerFeeAssetData === '0x' ?
        EMPTY_ADDRESS :
        assetDataUtils.decodeERC20AssetData(signedOrder.makerFeeAssetData).tokenAddress;
      const takerFeeAsset = signedOrder.takerFeeAssetData === '0x' ?
        EMPTY_ADDRESS :
        assetDataUtils.decodeERC20AssetData(signedOrder.takerFeeAssetData).tokenAddress;

      preFundHoldingsWeth = new BN(
        await call(vault, 'assetBalances', [weth.options.address])
      );
      preFundHoldingsMln = new BN(
        await call(vault, 'assetBalances', [mln.options.address])
      );

      const encodedArgs = encodeZeroExTakeOrderArgs(signedOrder, fillQuantity);

      tx = await send(
        vault,
        'callOnIntegration',
        [
          zeroExAdapter.options.address,
          takeOrderSignature,
          encodedArgs,
        ],
        managerTxOpts,
        web3
      );

      postFundHoldingsWeth = new BN(
        await call(vault, 'assetBalances', [weth.options.address])
      );
      postFundHoldingsMln = new BN(
        await call(vault, 'assetBalances', [mln.options.address])
      );
    });

    it('correctly updates fund holdings', async () => {
      expect(postFundHoldingsWeth).bigNumberEq(
        preFundHoldingsWeth.sub(new BN(signedOrder.takerAssetAmount))
      );
      expect(postFundHoldingsMln).bigNumberEq(
        preFundHoldingsMln.add(new BN(signedOrder.makerAssetAmount))
      );
    });

    it('emits correct OrderFilled event', async () => {
      const orderFilledCount = getEventCountFromLogs(
        tx.logs,
        CONTRACT_NAMES.ZERO_EX_V3_ADAPTER,
        'OrderFilled'
      );
      expect(orderFilledCount).toBe(1);

      const orderFilled = getEventFromLogs(
        tx.logs,
        CONTRACT_NAMES.ZERO_EX_V3_ADAPTER,
        'OrderFilled'
      );
      expect(orderFilled.targetContract).toBe(zeroExExchange.options.address);
      expect(orderFilled.buyAsset).toBe(makerTokenAddress);
      expect(orderFilled.buyAmount).toBe(signedOrder.makerAssetAmount);
      expect(orderFilled.sellAsset).toBe(takerTokenAddress);
      expect(orderFilled.sellAmount).toBe(signedOrder.takerAssetAmount);
      expect(orderFilled.feeAssets.length).toBe(0);
      expect(orderFilled.feeAmounts.length).toBe(0);
    });
  });

  describe('Fill Order 6: Partial amount, w/ protocol fee (taker asset), w/ taker fee in mln (maker asset)', () => {
    let signedOrder;
    let makerTokenAddress, takerTokenAddress, takerFee, takerFeeTokenAddress, fillQuantity;
    let makerFillQuantity, takerFillQuantity, takerFeeFillQuantity;
    let preFundHoldingsMln, postFundHoldingsMln;
    let preFundHoldingsWeth, postFundHoldingsWeth;
    let tx;

    beforeAll(async () => {
      fund = await setupFundWithParams({
        defaultTokens: [mln.options.address, weth.options.address],
        integrationAdapters: [zeroExAdapter.options.address],
        initialInvestment: {
          contribAmount: toWei('1', 'ether'),
          investor: deployer,
          tokenContract: weth
        },
        quoteToken: weth.options.address,
        fundFactory,
        manager,
        web3
      });
    });

    test('third party makes and validates an off-chain order', async () => {
      const makerAddress = deployer;
      const makerAssetAmount = toWei('1', 'Ether');
      const takerAssetAmount = toWei('0.05', 'Ether');
      const feeRecipientAddress = randomHex(20);
      const takerFee = toWei('0.001', 'ether');
      takerFeeTokenAddress = mln.options.address;
      makerTokenAddress = mln.options.address;
      takerTokenAddress = weth.options.address;
      fillQuantity = takerAssetAmount;

      const unsignedOrder = await createUnsignedZeroExOrder(
        zeroExExchange.options.address,
        chainId,
        {
          makerAddress,
          makerTokenAddress,
          makerAssetAmount,
          takerTokenAddress,
          takerAssetAmount,
          feeRecipientAddress,
          takerFee,
          takerFeeTokenAddress
        },
      );

      await send(mln, 'approve', [erc20Proxy.options.address, makerAssetAmount], defaultTxOpts, web3);
      signedOrder = await signZeroExOrder(unsignedOrder, deployer);
      const signatureValid = await call(
        zeroExExchange,
        'isValidOrderSignature',
        [signedOrder, signedOrder.signature]
      );

      expect(signatureValid).toBeTruthy();
    });

    test('half of the order is filled through the fund', async () => {
      const { vault } = fund;
      const partialFillDivisor = new BN(2);
      takerFillQuantity = new BN(signedOrder.takerAssetAmount).div(partialFillDivisor);
      makerFillQuantity = new BN(signedOrder.makerAssetAmount).div(partialFillDivisor);
      takerFeeFillQuantity = new BN(signedOrder.takerFee).div(partialFillDivisor);

      const makerFeeAsset = signedOrder.makerFeeAssetData === '0x' ?
        EMPTY_ADDRESS :
        assetDataUtils.decodeERC20AssetData(signedOrder.makerFeeAssetData).tokenAddress;
      const takerFeeAsset = signedOrder.takerFeeAssetData === '0x' ?
        EMPTY_ADDRESS :
        assetDataUtils.decodeERC20AssetData(signedOrder.takerFeeAssetData).tokenAddress;

      preFundHoldingsWeth = new BN(
        await call(vault, 'assetBalances', [weth.options.address])
      );
      preFundHoldingsMln = new BN(
        await call(vault, 'assetBalances', [mln.options.address])
      );

      const encodedArgs = encodeZeroExTakeOrderArgs(signedOrder, takerFillQuantity.toString());

      tx = await send(
        vault,
        'callOnIntegration',
        [
          zeroExAdapter.options.address,
          takeOrderSignature,
          encodedArgs,
        ],
        managerTxOpts,
        web3
      );

      postFundHoldingsWeth = new BN(
        await call(vault, 'assetBalances', [weth.options.address])
      );
      postFundHoldingsMln = new BN(
        await call(vault, 'assetBalances', [mln.options.address])
      );
    });

    it('correctly updates fund holdings', async () => {
      expect(postFundHoldingsWeth).bigNumberEq(
        preFundHoldingsWeth.sub(takerFillQuantity).sub(protocolFeeAmount)
      );
      expect(postFundHoldingsMln).bigNumberEq(
        preFundHoldingsMln.add(makerFillQuantity).sub(takerFeeFillQuantity)
      );
    });

    it('emits correct OrderFilled event', async () => {
      const orderFilledCount = getEventCountFromLogs(
        tx.logs,
        CONTRACT_NAMES.ZERO_EX_V3_ADAPTER,
        'OrderFilled'
      );
      expect(orderFilledCount).toBe(1);

      const orderFilled = getEventFromLogs(
        tx.logs,
        CONTRACT_NAMES.ZERO_EX_V3_ADAPTER,
        'OrderFilled'
      );
      expect(orderFilled.targetContract).toBe(zeroExExchange.options.address);
      expect(orderFilled.buyAsset).toBe(makerTokenAddress);
      expect(new BN(orderFilled.buyAmount)).bigNumberEq(makerFillQuantity);
      expect(orderFilled.sellAsset).toBe(takerTokenAddress);
      expect(new BN(orderFilled.sellAmount)).bigNumberEq(takerFillQuantity);
      expect(orderFilled.feeAssets.length).toBe(2);
      expect(orderFilled.feeAssets[0]).toBe(weth.options.address);
      expect(orderFilled.feeAssets[1]).toBe(takerFeeTokenAddress);
      expect(orderFilled.feeAmounts.length).toBe(2);
      expect(new BN(orderFilled.feeAmounts[0])).bigNumberEq(protocolFeeAmount);
      expect(new BN(orderFilled.feeAmounts[1])).bigNumberEq(takerFeeFillQuantity);
    });
  });
});
