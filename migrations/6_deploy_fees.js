const ManagementFee = artifacts.require('ManagementFee');
const PerformanceFee = artifacts.require('PerformanceFee');
const Registry = artifacts.require('Registry');

module.exports = async deployer => {
  const registry = await Registry.deployed();

  const managementFee = await deployer.deploy(ManagementFee, registry.address);
  const performanceFee = await deployer.deploy(PerformanceFee, registry.address);

  await registry.registerFee(managementFee.address);
  await registry.registerFee(performanceFee.address);
}
