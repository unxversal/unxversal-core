/* eslint-disable @typescript-eslint/no-explicit-any */
/* eslint-disable @typescript-eslint/no-unused-expressions */
import { loadFixture, time } from "@nomicfoundation/hardhat-toolbox/network-helpers";
import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import { TEST_CONSTANTS } from "../../shared/constants";

describe("GuardianPause", function () {
  let guardianPause: any;
  let mockTarget: any;
  let owner: SignerWithAddress;
  let guardian1: SignerWithAddress;
  let guardian2: SignerWithAddress;
  let guardian3: SignerWithAddress;
  let guardian4: SignerWithAddress;
  let guardian5: SignerWithAddress;
  let nonGuardian: SignerWithAddress;

  async function deployGuardianPauseFixture() {
    const [owner, guardian1, guardian2, guardian3, guardian4, guardian5, nonGuardian] = await ethers.getSigners();

    // Deploy mock target contract
    const MockERC20Factory = await ethers.getContractFactory("MockERC20");
    const mockTarget = await MockERC20Factory.deploy("Target", "TGT", 18, 0);

    // Deploy GuardianPause with initial guardians
    const GuardianPauseFactory = await ethers.getContractFactory("GuardianPause");
    const guardianPause = await GuardianPauseFactory.deploy(
      [guardian1.address, guardian2.address, guardian3.address, guardian4.address, guardian5.address]
    );

    return {
      guardianPause,
      mockTarget,
      owner,
      guardian1,
      guardian2,
      guardian3,
      guardian4,
      guardian5,
      nonGuardian
    };
  }

  beforeEach(async function () {
    const fixture = await loadFixture(deployGuardianPauseFixture);
    guardianPause = fixture.guardianPause;
    mockTarget = fixture.mockTarget;
    owner = fixture.owner;
    guardian1 = fixture.guardian1;
    guardian2 = fixture.guardian2;
    guardian3 = fixture.guardian3;
    guardian4 = fixture.guardian4;
    guardian5 = fixture.guardian5;
    nonGuardian = fixture.nonGuardian;
  });

  describe("Initialization", function () {
    it("Should set correct guardians", async function () {
      const GUARDIAN_ROLE = await guardianPause.GUARDIAN_ROLE();
      expect(await guardianPause.hasRole(GUARDIAN_ROLE, guardian1.address)).to.be.true;
      expect(await guardianPause.hasRole(GUARDIAN_ROLE, guardian2.address)).to.be.true;
      expect(await guardianPause.hasRole(GUARDIAN_ROLE, guardian3.address)).to.be.true;
      expect(await guardianPause.hasRole(GUARDIAN_ROLE, guardian4.address)).to.be.true;
      expect(await guardianPause.hasRole(GUARDIAN_ROLE, guardian5.address)).to.be.true;
      expect(await guardianPause.hasRole(GUARDIAN_ROLE, nonGuardian.address)).to.be.false;
    });

    it("Should set deployer as admin", async function () {
      const ADMIN_ROLE = await guardianPause.ADMIN_ROLE();
      expect(await guardianPause.hasRole(ADMIN_ROLE, owner.address)).to.be.true;
    });

    it("Should not be paused initially", async function () {
      expect(await guardianPause.isPaused(await mockTarget.getAddress())).to.be.false;
    });
  });

  describe("Guardian Management", function () {
    it("Should add new guardian", async function () {
      await expect(
        guardianPause.addGuardian(nonGuardian.address)
      ).to.emit(guardianPause, "GuardianAdded")
      .withArgs(nonGuardian.address);

      const GUARDIAN_ROLE = await guardianPause.GUARDIAN_ROLE();
      expect(await guardianPause.hasRole(GUARDIAN_ROLE, nonGuardian.address)).to.be.true;
    });

    it("Should remove guardian", async function () {
      await expect(
        guardianPause.removeGuardian(guardian1.address)
      ).to.emit(guardianPause, "GuardianRemoved")
      .withArgs(guardian1.address);

      const GUARDIAN_ROLE = await guardianPause.GUARDIAN_ROLE();
      expect(await guardianPause.hasRole(GUARDIAN_ROLE, guardian1.address)).to.be.false;
    });

    it("Should not allow non-admin to add guardian", async function () {
      await expect(
        guardianPause.connect(guardian1).addGuardian(nonGuardian.address)
      ).to.be.revertedWithCustomError(guardianPause, "AccessControlUnauthorizedAccount");
    });

    it("Should not allow non-admin to remove guardian", async function () {
      await expect(
        guardianPause.connect(guardian1).removeGuardian(guardian2.address)
      ).to.be.revertedWithCustomError(guardianPause, "AccessControlUnauthorizedAccount");
    });
  });

  describe("Pause Functionality", function () {
    it("Should allow guardian to pause contract", async function () {
      const target = await mockTarget.getAddress();
      
      await expect(
        guardianPause.connect(guardian1).pauseContract(target)
      ).to.emit(guardianPause, "ContractPaused");
      
      expect(await guardianPause.isPaused(target)).to.be.true;
    });

    it("Should not allow non-guardian to pause", async function () {
      const target = await mockTarget.getAddress();
      
      await expect(
        guardianPause.connect(nonGuardian).pauseContract(target)
      ).to.be.revertedWithCustomError(guardianPause, "AccessControlUnauthorizedAccount");
    });

    it("Should set pause expiry correctly", async function () {
      const target = await mockTarget.getAddress();
      
      await guardianPause.connect(guardian1).pauseContract(target);
      
      const pauseExpiry = await guardianPause.pauseExpiry(target);
      const expectedExpiry = await time.latest() + TEST_CONSTANTS.TIME.WEEK;
      
      expect(pauseExpiry).to.be.closeTo(expectedExpiry, 10); // Allow 10 second tolerance
    });

    it("Should not allow pausing already paused contract", async function () {
      const target = await mockTarget.getAddress();
      
      await guardianPause.connect(guardian1).pauseContract(target);
      
      await expect(
        guardianPause.connect(guardian2).pauseContract(target)
      ).to.be.revertedWith("Contract already paused");
    });
  });

  describe("Unpause Functionality", function () {
    beforeEach(async function () {
      const target = await mockTarget.getAddress();
      await guardianPause.connect(guardian1).pauseContract(target);
    });

    it("Should allow guardian to unpause contract", async function () {
      const target = await mockTarget.getAddress();
      
      await expect(
        guardianPause.connect(guardian1).unpauseContract(target)
      ).to.emit(guardianPause, "ContractUnpaused");
      
      expect(await guardianPause.isPaused(target)).to.be.false;
    });

    it("Should automatically unpause after 7 days", async function () {
      const target = await mockTarget.getAddress();
      
      expect(await guardianPause.isPaused(target)).to.be.true;
      
      await time.increase(TEST_CONSTANTS.TIME.WEEK + 1);
      
      expect(await guardianPause.isPaused(target)).to.be.false;
    });

    it("Should get remaining pause duration", async function () {
      const target = await mockTarget.getAddress();
      
      const remaining = await guardianPause.getPauseRemaining(target);
      expect(remaining).to.be.closeTo(TEST_CONSTANTS.TIME.WEEK, 10);
      
      await time.increase(TEST_CONSTANTS.TIME.DAY);
      
      const remainingAfter = await guardianPause.getPauseRemaining(target);
      expect(remainingAfter).to.be.closeTo(TEST_CONSTANTS.TIME.WEEK - TEST_CONSTANTS.TIME.DAY, 10);
    });
  });
}); 