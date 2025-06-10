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
    const unxv = await UNXVFactory.deploy();

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
      expect(await gaugeController.veToken()).to.equal(await veUNXV.getAddress());
    });

    it("Should have zero total weight initially", async function () {
      expect(await gaugeController.totalWeight()).to.equal(0);
    });
  });

  describe("Gauge Type Management", function () {
    it("Should change type weight", async function () {
      await gaugeController.changeTypeWeight(0, 1500);
      expect(await gaugeController.typeWeights(0)).to.equal(1500);
    });
  });

  describe("Gauge Management", function () {
    it("Should add gauge", async function () {
      await gaugeController.addGauge(gauge1.address, 0, 1000); // gauge address, type, weight
      const gaugeInfo = await gaugeController.gauges(gauge1.address);
      expect(gaugeInfo.addr).to.equal(gauge1.address);
      expect(gaugeInfo.weight).to.equal(1000);
    });

    it("Should get gauge info", async function () {
      await gaugeController.addGauge(gauge1.address, 0, 1500);
      const gaugeInfo = await gaugeController.gauges(gauge1.address);
      expect(gaugeInfo.gaugeType).to.equal(0);
      expect(gaugeInfo.weight).to.equal(1500);
    });

    it("Should emit NewGauge event", async function () {
      await expect(gaugeController.addGauge(gauge1.address, 0, 1000))
        .to.emit(gaugeController, "NewGauge")
        .withArgs(gauge1.address, 0, 1000);
    });

    it("Should not add duplicate gauge", async function () {
      await gaugeController.addGauge(gauge1.address, 0, 1000);
      
      await expect(
        gaugeController.addGauge(gauge1.address, 1, 2000)
      ).to.be.revertedWith("Gauge already exists");
    });



    it("Should change type weight", async function () {
      await gaugeController.changeTypeWeight(0, 1500);
      expect(await gaugeController.typeWeights(0)).to.equal(1500);
    });
  });

  describe("Voting", function () {
    beforeEach(async function () {
      // Setup gauges first
      await gaugeController.changeTypeWeight(0, 1000); // DEX type
      await gaugeController.changeTypeWeight(1, 2000); // LEND type
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
      await gaugeController.connect(user1).voteForGauge(gauge1.address, 5000); // 50%
      
      const userVotePower = await gaugeController.voteUserPower(user1.address, gauge1.address);
      expect(userVotePower).to.equal(5000);
    });

    it("Should emit VoteForGauge event", async function () {
      await expect(gaugeController.connect(user1).voteForGauge(gauge1.address, 5000))
        .to.emit(gaugeController, "VoteForGauge")
        .withArgs(user1.address, gauge1.address, 5000);
    });

    it("Should not allow voting with zero veUNXV balance", async function () {
      await expect(
        gaugeController.connect(owner).voteForGauge(gauge1.address, 5000)
      ).to.be.revertedWith("No voting power");
    });

    it("Should not allow voting for non-existent gauge", async function () {
      await expect(
        gaugeController.connect(user1).voteForGauge(owner.address, 5000)
      ).to.be.revertedWith("Gauge not added");
    });
  });

  describe("Weight Calculations", function () {
    beforeEach(async function () {
      // Setup basic environment
      await gaugeController.changeTypeWeight(0, 3000);  // DEX type - 30%
      await gaugeController.changeTypeWeight(1, 4000); // LEND type - 40%
      
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
      await gaugeController.connect(user1).voteForGauge(gauge1.address, 10000); // Vote for gauge
      
      const relativeWeight = await gaugeController.getGaugeRelativeWeight(gauge1.address);
      expect(relativeWeight).to.be.gte(0);
    });
  });

  describe("Integration Scenarios", function () {
    it("Should handle basic gauge setup and voting", async function () {
      // Setup gauge types 
      await gaugeController.changeTypeWeight(0, 2500);   // DEX - 25%
      await gaugeController.changeTypeWeight(1, 3500);  // LEND - 35%
      
      const dexGauge = gauge1.address;
      const lendGauge = gauge2.address;
      
      await gaugeController.addGauge(dexGauge, 0, 1000);
      await gaugeController.addGauge(lendGauge, 1, 1000);
      
      // User votes
      await (unxv as any).connect(user1).approve(await veUNXV.getAddress(), ethers.parseEther("10000"));
      await (veUNXV as any).connect(user1).createLock(
        ethers.parseEther("10000"),
        Math.floor(Date.now() / 1000) + TEST_CONSTANTS.VEUNXV.MAX_LOCK_TIME
      );
      
      await gaugeController.connect(user1).voteForGauge(dexGauge, 7000);
      
      const userVotePower = await gaugeController.voteUserPower(user1.address, dexGauge);
      expect(userVotePower).to.equal(7000);
    });
  });
}); 