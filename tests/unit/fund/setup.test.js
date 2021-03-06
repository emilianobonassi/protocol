import { toWei } from 'web3-utils';
import { send } from '~/utils/deploy-contract';
import { CONTRACT_NAMES } from '~/utils/constants';
import { getDeployed } from '~/utils/getDeployed';
import mainnetAddrs from '~/config';

let deployer, manager, user;
let defaultTxOpts, managerTxOpts, userTxOpts;
let fundFactory;

beforeAll(async () => {
  [deployer, manager, user] = await web3.eth.getAccounts();
  defaultTxOpts = { from: deployer, gas: 8000000 };
  managerTxOpts = { ...defaultTxOpts, from: manager };
  userTxOpts = { ...defaultTxOpts, from: user };

  const mln = getDeployed(CONTRACT_NAMES.ERC20_WITH_FIELDS, mainnetAddrs.tokens.MLN);
  const weth = getDeployed(CONTRACT_NAMES.WETH, mainnetAddrs.tokens.WETH);
  fundFactory = getDeployed(CONTRACT_NAMES.FUND_FACTORY);
  
  await send(
    fundFactory,
    'beginFundSetup',
    [
      `test-fund-${Date.now()}`,
      [],
      [],
      [],
      [],
      [],
      [],
      weth.options.address
    ],
    managerTxOpts
  );
});

test('continue setup of a fund', async () => {
  const amguTxValue = toWei('0.01', 'ether')
  const userTxOptsWithAmgu = { ...userTxOpts, value: amguTxValue };
  
  await send(fundFactory, 'createFeeManagerFor', [manager], userTxOptsWithAmgu);
  await send(fundFactory, 'createPolicyManagerFor', [manager], userTxOptsWithAmgu);
  await send(fundFactory, 'createSharesFor', [manager], userTxOptsWithAmgu);
  await send(fundFactory, 'createVaultFor', [manager], userTxOptsWithAmgu);
  const res = await send(fundFactory, 'completeFundSetupFor', [manager], userTxOptsWithAmgu);
  expect(res).toBeTruthy();
});
