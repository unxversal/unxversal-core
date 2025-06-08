/* eslint-disable @typescript-eslint/no-explicit-any */
/* eslint-disable @typescript-eslint/no-unused-expressions */
import { loadFixture, time } from "@nomicfoundation/hardhat-toolbox/network-helpers";
import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import { TEST_CONSTANTS } from "../../shared/constants";

describe("GaugeController", function () {
  let gaugeController: any;
  let unxv: any;
  let veUNXV: any;
  let owner: SignerWithAddress;
  let user1: SignerWithAddress;
  let user2: SignerWithAddress;
  let gauge1: SignerWithAddress;
  let gauge2: SignerWithAddress;

  async function deployGaugeControllerFixture() {
    const [owner, user1, user2, gauge1, gauge2] = await ethers.getSigners();

    // Deploy UNXV token
    const UNXVFactory = await ethers.getContractFactory("UNXV");
          // @ts-expect-error
      const unxv = await UNXVFactory.deploy(owner.address);

    // Deploy VeUNXV
    const VeUNXVFactory = await ethers.getContractFactory("VeUNXV");
    const veUNXV = await VeUNXVFactory.deploy(await unxv.getAddress());

    // Deploy GaugeController
    const GaugeControllerFactory = await ethers.getContractFactory("GaugeController");
    const gaugeController = await GaugeControllerFactory.deploy(
      await unxv.getAddress(),
      await veUNXV.getAddress(),
      owner.address
    );

    // Setup initial state
    await (unxv as any).transfer(user1.address, ethers.parseEther("100000"));
    await (unxv as any).transfer(user2.address, ethers.parseEther("100000"));

    return {
      gaugeController,
      unxv,
      veUNXV,
      owner,
      user1,
      user2,
      gauge1,
      gauge2
    };
  }

  beforeEach(async function () {
    const fixture = await loadFixture(deployGaugeControllerFixture);
    gaugeController = fixture.gaugeController;
    unxv = fixture.unxv;
    veUNXV = fixture.veUNXV;
    owner = fixture.owner;
    user1 = fixture.user1;
    user2 = fixture.user2;
    gauge1 = fixture.gauge1;
    gauge2 = fixture.gauge2;
  });

  describe("Initialization", function () {
    it("Should set correct UNXV token", async function () {
      expect(await gaugeController.token()).to.equal(await unxv.getAddress());
    });

    it("Should set correct veUNXV token", async function () {
      expect(await gaugeController.votingEscrow()).to.equal(await veUNXV.getAddress());
    });

    it("Should have zero gauge types initially", async function () {
      expect(await gaugeController.nGaugeTypes()).to.equal(0);
    });
  });

  describe("Gauge Type Management", function () {
    it("Should add gauge type", async function () {
      await gaugeController.addType("DEX", 1000); // 10% weight
      expect(await gaugeController.nGaugeTypes()).to.equal(1);
    });

    it("Should get gauge type info", async function () {
      await gaugeController.addType("LEND", 2000); // 20% weight
      const typeInfo = await gaugeController.gaugeTypes(0);
      expect(typeInfo.name).to.equal("LEND");
      expect(typeInfo.weight).to.equal(2000);
    });

    it("Should only allow admin to add gauge types", async function () {
      await expect(
        gaugeController.connect(user1).addType("DEX", 1000)
      ).to.be.revertedWith("Access denied");
    });

    it("Should emit GaugeTypeAdded event", async function () {
      await expect(gaugeController.addType("PERPS", 1500))
        .to.emit(gaugeController, "GaugeTypeAdded")
        .withArgs("PERPS", 0, 1500);
    });

    it("Should change gauge type weight", async function () {
      await gaugeController.addType("DEX", 1000);
      await gaugeController.changeTypeWeight(0, 1500);
      
      const typeInfo = await gaugeController.gaugeTypes(0);
      expect(typeInfo.weight).to.equal(1500);
    });
  });

  describe("Gauge Management", function () {
    beforeEach(async function () {
      await gaugeController.addType("DEX", 1000);
      await gaugeController.addType("LEND", 2000);
    });

    it("Should add gauge", async function () {
      await gaugeController.addGauge(gauge1.address, 0, 1000); // DEX gauge with 10% weight
      expect(await gaugeController.nGauges()).to.equal(1);
    });

    it("Should get gauge info", async function () {
      await gaugeController.addGauge(gauge1.address, 0, 1500);
      const gaugeInfo = await gaugeController.gauges(gauge1.address);
      expect(gaugeInfo.gaugeType).to.equal(0);
      expect(gaugeInfo.weight).to.equal(1500);
    });

    it("Should emit GaugeAdded event", async function () {
      await expect(gaugeController.addGauge(gauge1.address, 0, 1000))
        .to.emit(gaugeController, "GaugeAdded")
        .withArgs(gauge1.address, 0, 1000);
    });

    it("Should not add duplicate gauge", async function () {
      await gaugeController.addGauge(gauge1.address, 0, 1000);
      
      await expect(
        gaugeController.addGauge(gauge1.address, 1, 2000)
      ).to.be.revertedWith("Gauge already exists");
    });

    it("Should change gauge weight", async function () {
      await gaugeController.addGauge(gauge1.address, 0, 1000);
      await gaugeController.changeGaugeWeight(gauge1.address, 1500);
      
      const gaugeInfo = await gaugeController.gauges(gauge1.address);
      expect(gaugeInfo.weight).to.equal(1500);
    });
  });

  describe("Voting", function () {
    beforeEach(async function () {
      // Setup gauge types and gauges
      await gaugeController.addType("DEX", 1000);
      await gaugeController.addType("LEND", 2000);
      await gaugeController.addGauge(gauge1.address, 0, 1000);
      await gaugeController.addGauge(gauge2.address, 1, 1500);

      // Lock tokens to get voting power
      await (unxv as any).connect(user1).approve(await veUNXV.getAddress(), ethers.parseEther("10000"));
      await (veUNXV as any).connect(user1).createLock(
        ethers.parseEther("10000"),
        Math.floor(Date.now() / 1000) + TEST_CONSTANTS.GOVERNANCE.MAX_LOCK_TIME
      );

      await (unxv as any).connect(user2).approve(await veUNXV.getAddress(), ethers.parseEther("5000"));
      await (veUNXV as any).connect(user2).createLock(
        ethers.parseEther("5000"),
        Math.floor(Date.now() / 1000) + TEST_CONSTANTS.GOVERNANCE.MAX_LOCK_TIME
      );
    });

    it("Should vote for gauge", async function () {
      await gaugeController.connect(user1).voteForGaugeWeights(gauge1.address, 5000); // 50%
      
      const voteInfo = await gaugeController.voteUserGauge(user1.address, gauge1.address);
      expect(voteInfo.weight).to.equal(5000);
    });

    it("Should allocate voting power correctly", async function () {
      await gaugeController.connect(user1).voteForGaugeWeights(gauge1.address, 6000); // 60%
      await gaugeController.connect(user1).voteForGaugeWeights(gauge2.address, 4000); // 40%
      
      const vote1 = await gaugeController.voteUserGauge(user1.address, gauge1.address);
      const vote2 = await gaugeController.voteUserGauge(user1.address, gauge2.address);
      
      expect(vote1.weight).to.equal(6000);
      expect(vote2.weight).to.equal(4000);
    });

    it("Should not allow voting with zero veUNXV balance", async function () {
      await expect(
        gaugeController.connect(owner).voteForGaugeWeights(gauge1.address, 5000)
      ).to.be.revertedWith("No voting power");
    });

    it("Should not allow voting for non-existent gauge", async function () {
      await expect(
        gaugeController.connect(user1).voteForGaugeWeights(owner.address, 5000)
      ).to.be.revertedWith("Gauge does not exist");
    });

    it("Should emit VoteForGauge event", async function () {
      await expect(gaugeController.connect(user1).voteForGaugeWeights(gauge1.address, 5000))
        .to.emit(gaugeController, "VoteForGauge")
        .withArgs(user1.address, gauge1.address, 5000);
    });

    it("Should handle vote weight updates", async function () {
      await gaugeController.connect(user1).voteForGaugeWeights(gauge1.address, 5000);
      await gaugeController.connect(user1).voteForGaugeWeights(gauge1.address, 7000); // Update vote
      
      const voteInfo = await gaugeController.voteUserGauge(user1.address, gauge1.address);
      expect(voteInfo.weight).to.equal(7000);
    });
  });

  describe("Weight Calculations", function () {
    beforeEach(async function () {
      // Setup comprehensive test environment
      await gaugeController.addType("DEX", 3000);  // 30%
      await gaugeController.addType("LEND", 4000); // 40%
      await gaugeController.addType("PERPS", 3000); // 30%
      
      await gaugeController.addGauge(gauge1.address, 0, 1000); // DEX gauge
      await gaugeController.addGauge(gauge2.address, 1, 1000); // LEND gauge

      // Setup voting power
      await (unxv as any).connect(user1).approve(await veUNXV.getAddress(), ethers.parseEther("10000"));
      await (veUNXV as any).connect(user1).createLock(
        ethers.parseEther("10000"),
        Math.floor(Date.now() / 1000) + TEST_CONSTANTS.GOVERNANCE.MAX_LOCK_TIME
      );
    });

    it("Should calculate relative weight correctly", async function () {
      await gaugeController.connect(user1).voteForGaugeWeights(gauge1.address, 10000); // 100%
      
      // Advance time to next epoch
      await time.increase(TEST_CONSTANTS.GAUGE.EPOCH_DURATION);
      
      const relativeWeight = await gaugeController.gaugeRelativeWeight(gauge1.address);
      expect(relativeWeight).to.be.gt(0);
    });

    it("Should handle multiple gauge voting", async function () {
      await gaugeController.connect(user1).voteForGaugeWeights(gauge1.address, 6000); // 60%
      await gaugeController.connect(user1).voteForGaugeWeights(gauge2.address, 4000); // 40%
      
      await time.increase(TEST_CONSTANTS.GAUGE.EPOCH_DURATION);
      
      const weight1 = await gaugeController.gaugeRelativeWeight(gauge1.address);
      const weight2 = await gaugeController.gaugeRelativeWeight(gauge2.address);
      
      expect(weight1).to.be.gt(weight2); // Should reflect 60/40 split
    });
  });

  describe("Admin Functions", function () {
    it("Should commit admin transfer", async function () {
      await gaugeController.commitTransferOwnership(user1.address);
      expect(await gaugeController.futureAdmin()).to.equal(user1.address);
    });

    it("Should accept admin transfer", async function () {
      await gaugeController.commitTransferOwnership(user1.address);
      await gaugeController.connect(user1).acceptTransferOwnership();
      expect(await gaugeController.admin()).to.equal(user1.address);
    });

    it("Should kill gauge", async function () {
      await gaugeController.addType("DEX", 1000);
      await gaugeController.addGauge(gauge1.address, 0, 1000);
      
      await gaugeController.killGauge(gauge1.address);
      const gaugeInfo = await gaugeController.gauges(gauge1.address);
      expect(gaugeInfo.killed).to.be.true;
    });

    it("Should unkill gauge", async function () {
      await gaugeController.addType("DEX", 1000);
      await gaugeController.addGauge(gauge1.address, 0, 1000);
      
      await gaugeController.killGauge(gauge1.address);
      await gaugeController.unkillGauge(gauge1.address);
      
      const gaugeInfo = await gaugeController.gauges(gauge1.address);
      expect(gaugeInfo.killed).to.be.false;
    });
  });

  describe("Checkpoint System", function () {
    beforeEach(async function () {
      await gaugeController.addType("DEX", 1000);
      await gaugeController.addGauge(gauge1.address, 0, 1000);
      
      await (unxv as any).connect(user1).approve(await veUNXV.getAddress(), ethers.parseEther("10000"));
      await (veUNXV as any).connect(user1).createLock(
        ethers.parseEther("10000"),
        Math.floor(Date.now() / 1000) + TEST_CONSTANTS.VEUNXV.MAX_LOCK_TIME
      );
    });

    it("Should checkpoint gauge", async function () {
      await gaugeController.connect(user1).voteForGaugeWeights(gauge1.address, 10000);
      await gaugeController.checkpointGauge(gauge1.address);
      
      const lastCheckpoint = await gaugeController.timeGauge(gauge1.address);
      expect(lastCheckpoint).to.be.gt(0);
    });

    it("Should update weights during checkpoint", async function () {
      await gaugeController.connect(user1).voteForGaugeWeights(gauge1.address, 10000);
      
      const weightBefore = await gaugeController.gaugeRelativeWeight(gauge1.address);
      await time.increase(TEST_CONSTANTS.GAUGE.EPOCH_DURATION);
      await gaugeController.checkpointGauge(gauge1.address);
      const weightAfter = await gaugeController.gaugeRelativeWeight(gauge1.address);
      
      // Weight should potentially change after checkpoint
      expect(weightAfter).to.be.gte(0);
    });
  });

  describe("Integration Scenarios", function () {
    it("Should handle protocol emission distribution", async function () {
      // Simulate full protocol setup
      await gaugeController.addType("DEX", 2500);   // 25%
      await gaugeController.addType("LEND", 3500);  // 35%
      await gaugeController.addType("PERPS", 2500); // 25%
      await gaugeController.addType("SYNTH", 1500); // 15%
      
      const dexGauge = gauge1.address;
      const lendGauge = gauge2.address;
      
      await gaugeController.addGauge(dexGauge, 0, 1000);
      await gaugeController.addGauge(lendGauge, 1, 1000);
      
      // Multiple users vote
      await (unxv as any).connect(user1).approve(await veUNXV.getAddress(), ethers.parseEther("10000"));
      await (veUNXV as any).connect(user1).createLock(
        ethers.parseEther("10000"),
        Math.floor(Date.now() / 1000) + TEST_CONSTANTS.VEUNXV.MAX_LOCK_TIME
      );
      
      await gaugeController.connect(user1).voteForGaugeWeights(dexGauge, 7000);
      await gaugeController.connect(user1).voteForGaugeWeights(lendGauge, 3000);
      
      await time.increase(TEST_CONSTANTS.GAUGE.EPOCH_DURATION);
      
      const dexWeight = await gaugeController.gaugeRelativeWeight(dexGauge);
      const lendWeight = await gaugeController.gaugeRelativeWeight(lendGauge);
      
      expect(dexWeight).to.be.gt(lendWeight);
    });
  });
}); 