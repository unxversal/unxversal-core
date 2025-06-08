import { ethers } from "hardhat";

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying contracts with the account:", deployer.address);

  // Deploy UNXV token
  const UNXV = await ethers.getContractFactory("UNXV");
  const unxv = await UNXV.deploy();
  await unxv.waitForDeployment();
  console.log("UNXV deployed to:", await unxv.getAddress());

  // Deploy VeUNXV
  const VeUNXV = await ethers.getContractFactory("VeUNXV");
  const veUnxv = await VeUNXV.deploy(await unxv.getAddress());
  await veUnxv.waitForDeployment();
  console.log("VeUNXV deployed to:", await veUnxv.getAddress());

  // Deploy Timelock with 48h delay
  const delay = 48 * 60 * 60; // 48 hours
  const TimelockController = await ethers.getContractFactory("TimelockController");
  const timelock = await TimelockController.deploy(
    delay,
    [deployer.address], // proposers
    [deployer.address], // executors
    deployer.address // admin
  );
  await timelock.waitForDeployment();
  console.log("Timelock deployed to:", await timelock.getAddress());

  // Deploy Governor
  const votingDelay = 1; // 1 block
  const votingPeriod = 50400; // ~1 week
  const proposalThreshold = ethers.parseEther("10000"); // 10k UNXV
  const quorumPercentage = 4; // 4%

  const UnxversalGovernor = await ethers.getContractFactory("UnxversalGovernor");
  const governor = await UnxversalGovernor.deploy(
    await unxv.getAddress(),
    await timelock.getAddress(),
    votingDelay,
    votingPeriod,
    proposalThreshold,
    quorumPercentage
  );
  await governor.waitForDeployment();
  console.log("Governor deployed to:", await governor.getAddress());

  // Deploy GaugeController
  const GaugeController = await ethers.getContractFactory("GaugeController");
  const gaugeController = await GaugeController.deploy(
    await unxv.getAddress(),
    await veUnxv.getAddress()
  );
  await gaugeController.waitForDeployment();
  console.log("GaugeController deployed to:", await gaugeController.getAddress());

  // Deploy Treasury
  const Treasury = await ethers.getContractFactory("Treasury");
  const treasury = await Treasury.deploy();
  await treasury.waitForDeployment();
  console.log("Treasury deployed to:", await treasury.getAddress());

  // Deploy GuardianPause with initial guardians
  const initialGuardians = [
    deployer.address,
    // Add other guardian addresses here
  ];
  const GuardianPause = await ethers.getContractFactory("GuardianPause");
  const guardianPause = await GuardianPause.deploy(initialGuardians);
  await guardianPause.waitForDeployment();
  console.log("GuardianPause deployed to:", await guardianPause.getAddress());

  // Setup phase
  console.log("\nSetting up contracts...");

  // Transfer Treasury ownership to Timelock
  await treasury.transferOwnership(await timelock.getAddress());
  console.log("Treasury ownership transferred to Timelock");

  // Finish UNXV minting
  await unxv.finishMinting();
  console.log("UNXV minting finished");

  // Set up initial gauge types and weights
  const gaugeTypes = {
    DEX: 0,
    LEND: 1,
    SYNTH: 2,
    PERPS: 3
  };

  // Initial weights (can be adjusted by governance later)
  const typeWeights = {
    [gaugeTypes.DEX]: ethers.parseEther("0.25"), // 25%
    [gaugeTypes.LEND]: ethers.parseEther("0.25"), // 25%
    [gaugeTypes.SYNTH]: ethers.parseEther("0.20"), // 20%
    [gaugeTypes.PERPS]: ethers.parseEther("0.30")  // 30%
  };

  for (const [type, weight] of Object.entries(typeWeights)) {
    await gaugeController.changeTypeWeight(type, weight);
    console.log(`Set gauge type ${type} weight to ${weight}`);
  }

  console.log("\nDeployment complete!");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
}); 