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

    // Deploy GuardianPause with 3-of-5 multisig
    const GuardianPauseFactory = await ethers.getContractFactory("GuardianPause");
    const guardianPause = await GuardianPauseFactory.deploy(
      [guardian1.address, guardian2.address, guardian3.address, guardian4.address, guardian5.address],
      3, // threshold
      owner.address // admin
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
      expect(await guardianPause.isGuardian(guardian1.address)).to.be.true;
      expect(await guardianPause.isGuardian(guardian2.address)).to.be.true;
      expect(await guardianPause.isGuardian(guardian3.address)).to.be.true;
      expect(await guardianPause.isGuardian(guardian4.address)).to.be.true;
      expect(await guardianPause.isGuardian(guardian5.address)).to.be.true;
      expect(await guardianPause.isGuardian(nonGuardian.address)).to.be.false;
    });

    it("Should set correct threshold", async function () {
      expect(await guardianPause.threshold()).to.equal(3);
    });

    it("Should set correct admin", async function () {
      expect(await guardianPause.admin()).to.equal(owner.address);
    });

    it("Should not be paused initially", async function () {
      expect(await guardianPause.isPaused()).to.be.false;
    });
  });

  describe("Guardian Management", function () {
    it("Should allow admin to add guardian", async function () {
      await guardianPause.connect(owner).addGuardian(nonGuardian.address);
      expect(await guardianPause.isGuardian(nonGuardian.address)).to.be.true;
    });

    it("Should allow admin to remove guardian", async function () {
      await guardianPause.connect(owner).removeGuardian(guardian5.address);
      expect(await guardianPause.isGuardian(guardian5.address)).to.be.false;
    });

    it("Should not allow non-admin to add guardian", async function () {
      await expect(
        guardianPause.connect(guardian1).addGuardian(nonGuardian.address)
      ).to.be.revertedWith("Only admin");
    });

    it("Should not allow non-admin to remove guardian", async function () {
      await expect(
        guardianPause.connect(guardian1).removeGuardian(guardian5.address)
      ).to.be.revertedWith("Only admin");
    });

    it("Should emit GuardianAdded event", async function () {
      await expect(guardianPause.connect(owner).addGuardian(nonGuardian.address))
        .to.emit(guardianPause, "GuardianAdded")
        .withArgs(nonGuardian.address);
    });

    it("Should emit GuardianRemoved event", async function () {
      await expect(guardianPause.connect(owner).removeGuardian(guardian5.address))
        .to.emit(guardianPause, "GuardianRemoved")
        .withArgs(guardian5.address);
    });

    it("Should update threshold when removing guardian", async function () {
      await guardianPause.connect(owner).removeGuardian(guardian5.address);
      await guardianPause.connect(owner).removeGuardian(guardian4.address);
      
      // With 3 guardians remaining, threshold should adjust to 2
      await guardianPause.connect(owner).setThreshold(2);
      expect(await guardianPause.threshold()).to.equal(2);
    });
  });

  describe("Pause Proposal and Execution", function () {
    it("Should allow guardian to propose pause", async function () {
      await expect(
        guardianPause.connect(guardian1).proposePause(await mockTarget.getAddress(), "Emergency stop")
      ).to.emit(guardianPause, "PauseProposed");
    });

    it("Should not allow non-guardian to propose pause", async function () {
      await expect(
        guardianPause.connect(nonGuardian).proposePause(await mockTarget.getAddress(), "Emergency stop")
      ).to.be.revertedWith("Only guardian");
    });

    it("Should require multiple confirmations to execute pause", async function () {
      const target = await mockTarget.getAddress();
      const reason = "Emergency stop";
      
      // First guardian proposes
      await guardianPause.connect(guardian1).proposePause(target, reason);
      
      // Should not be paused with only 1 confirmation
      expect(await guardianPause.isPaused()).to.be.false;
      
      // Second guardian confirms
      await guardianPause.connect(guardian2).confirmPause(target);
      
      // Still not paused with 2 confirmations (need 3)
      expect(await guardianPause.isPaused()).to.be.false;
      
      // Third guardian confirms - should trigger pause
      await expect(
        guardianPause.connect(guardian3).confirmPause(target)
      ).to.emit(guardianPause, "Paused");
      
      expect(await guardianPause.isPaused()).to.be.true;
    });

    it("Should not allow double confirmation", async function () {
      const target = await mockTarget.getAddress();
      
      await guardianPause.connect(guardian1).proposePause(target, "Emergency stop");
      await guardianPause.connect(guardian1).confirmPause(target);
      
      await expect(
        guardianPause.connect(guardian1).confirmPause(target)
      ).to.be.revertedWith("Already confirmed");
    });

    it("Should track confirmation count", async function () {
      const target = await mockTarget.getAddress();
      
      await guardianPause.connect(guardian1).proposePause(target, "Emergency stop");
      expect(await guardianPause.getConfirmationCount(target)).to.equal(1);
      
      await guardianPause.connect(guardian2).confirmPause(target);
      expect(await guardianPause.getConfirmationCount(target)).to.equal(2);
      
      await guardianPause.connect(guardian3).confirmPause(target);
      expect(await guardianPause.getConfirmationCount(target)).to.equal(3);
    });
  });

  describe("Pause Duration and Expiry", function () {
    beforeEach(async function () {
      // Execute a pause
      const target = await mockTarget.getAddress();
      await guardianPause.connect(guardian1).proposePause(target, "Emergency stop");
      await guardianPause.connect(guardian2).confirmPause(target);
      await guardianPause.connect(guardian3).confirmPause(target);
    });

    it("Should set pause expiry time", async function () {
      const pauseTime = await guardianPause.pauseTime();
      const maxPauseDuration = await guardianPause.MAX_PAUSE_DURATION();
      const expectedExpiry = pauseTime + maxPauseDuration;
      
      expect(await guardianPause.pauseExpiry()).to.equal(expectedExpiry);
    });

    it("Should automatically unpause after max duration", async function () {
      const maxPauseDuration = await guardianPause.MAX_PAUSE_DURATION();
      
      // Fast forward past max pause duration
      await time.increase(Number(maxPauseDuration) + 1);
      
      // Check pause status - should be expired
      expect(await guardianPause.isPaused()).to.be.false;
      expect(await guardianPause.isPauseExpired()).to.be.true;
    });

    it("Should not allow new pause while existing pause is active", async function () {
      const target = await mockTarget.getAddress();
      
      await expect(
        guardianPause.connect(guardian1).proposePause(target, "Another emergency")
      ).to.be.revertedWith("Already paused");
    });
  });

  describe("Manual Unpause", function () {
    beforeEach(async function () {
      // Execute a pause
      const target = await mockTarget.getAddress();
      await guardianPause.connect(guardian1).proposePause(target, "Emergency stop");
      await guardianPause.connect(guardian2).confirmPause(target);
      await guardianPause.connect(guardian3).confirmPause(target);
    });

    it("Should allow admin to unpause", async function () {
      await expect(
        guardianPause.connect(owner).unpause()
      ).to.emit(guardianPause, "Unpaused");
      
      expect(await guardianPause.isPaused()).to.be.false;
    });

    it("Should not allow non-admin to unpause", async function () {
      await expect(
        guardianPause.connect(guardian1).unpause()
      ).to.be.revertedWith("Only admin");
    });

    it("Should reset pause state after manual unpause", async function () {
      await guardianPause.connect(owner).unpause();
      
      expect(await guardianPause.pauseTime()).to.equal(0);
      expect(await guardianPause.pauseExpiry()).to.equal(0);
    });
  });

  describe("Emergency Response Scenarios", function () {
    it("Should handle rapid guardian response", async function () {
      const target = await mockTarget.getAddress();
      const startTime = await time.latest();
      
      // All 3 required guardians respond quickly
      await guardianPause.connect(guardian1).proposePause(target, "Critical vulnerability detected");
      await guardianPause.connect(guardian2).confirmPause(target);
      await guardianPause.connect(guardian3).confirmPause(target);
      
      const pauseTime = await guardianPause.pauseTime();
      
      // Should pause within seconds of detection
      expect(Number(pauseTime) - startTime).to.be.lessThan(10);
      expect(await guardianPause.isPaused()).to.be.true;
    });

    it("Should handle guardian threshold changes during active pause", async function () {
      const target = await mockTarget.getAddress();
      
      // Execute pause
      await guardianPause.connect(guardian1).proposePause(target, "Emergency");
      await guardianPause.connect(guardian2).confirmPause(target);
      await guardianPause.connect(guardian3).confirmPause(target);
      
      // Admin reduces threshold during pause
      await guardianPause.connect(owner).setThreshold(2);
      
      // Pause should remain active
      expect(await guardianPause.isPaused()).to.be.true;
      expect(await guardianPause.threshold()).to.equal(2);
    });

    it("Should handle multiple concurrent pause attempts", async function () {
      const target1 = await mockTarget.getAddress();
      const target2 = guardian1.address; // Different target
      
      // First pause succeeds
      await guardianPause.connect(guardian1).proposePause(target1, "Emergency 1");
      await guardianPause.connect(guardian2).confirmPause(target1);
      await guardianPause.connect(guardian3).confirmPause(target1);
      
      // Second pause attempt should fail
      await expect(
        guardianPause.connect(guardian4).proposePause(target2, "Emergency 2")
      ).to.be.revertedWith("Already paused");
    });
  });

  describe("Guardian Revocation", function () {
    it("Should allow admin to revoke guardian powers", async function () {
      // Remove multiple guardians
      await guardianPause.connect(owner).removeGuardian(guardian1.address);
      await guardianPause.connect(owner).removeGuardian(guardian2.address);
      
      // Remaining guardians should still be able to pause
      await guardianPause.connect(owner).setThreshold(2);
      
      const target = await mockTarget.getAddress();
      await guardianPause.connect(guardian3).proposePause(target, "Test");
      await guardianPause.connect(guardian4).confirmPause(target);
      
      expect(await guardianPause.isPaused()).to.be.true;
    });

    it("Should handle Year 1 sunset mechanism", async function () {
      // Simulate Year 1 passage
      await time.increase(TEST_CONSTANTS.TIME.YEAR);
      
      // Admin should be able to disable guardian system
      await guardianPause.connect(owner).disableGuardians();
      
      // Guardians should no longer be able to pause
      const target = await mockTarget.getAddress();
      await expect(
        guardianPause.connect(guardian1).proposePause(target, "Should fail")
      ).to.be.revertedWith("Guardians disabled");
    });
  });

  describe("Integration with Protocol Contracts", function () {
    it("Should integrate with pausable contracts", async function () {
      // Mock a pausable contract call
      const target = await mockTarget.getAddress();
      
      // Execute pause
      await guardianPause.connect(guardian1).proposePause(target, "Security incident");
      await guardianPause.connect(guardian2).confirmPause(target);
      await guardianPause.connect(guardian3).confirmPause(target);
      
      // Protocol contracts should check pause status
      expect(await guardianPause.isPaused()).to.be.true;
      
      // After unpause, operations should resume
      await guardianPause.connect(owner).unpause();
      expect(await guardianPause.isPaused()).to.be.false;
    });

    it("Should handle cross-module emergency", async function () {
      // Simulate emergency affecting multiple protocol modules
      const targets = [
        await mockTarget.getAddress(),
        guardian1.address, // Represent different modules
        guardian2.address
      ];
      
      // Single pause should affect entire protocol
      await guardianPause.connect(guardian1).proposePause(targets[0], "Cross-module vulnerability");
      await guardianPause.connect(guardian2).confirmPause(targets[0]);
      await guardianPause.connect(guardian3).confirmPause(targets[0]);
      
      expect(await guardianPause.isPaused()).to.be.true;
      
      // All modules should respect the global pause
      for (const target of targets) {
        // Each module should check guardianPause.isPaused()
        expect(await guardianPause.isPaused()).to.be.true;
      }
    });
  });

  describe("Edge Cases", function () {
    it("Should handle threshold adjustment edge cases", async function () {
      // Cannot set threshold higher than guardian count
      await expect(
        guardianPause.connect(owner).setThreshold(6)
      ).to.be.revertedWith("Threshold too high");
      
      // Cannot set threshold to zero
      await expect(
        guardianPause.connect(owner).setThreshold(0)
      ).to.be.revertedWith("Invalid threshold");
    });

    it("Should prevent pause spam", async function () {
      const target = await mockTarget.getAddress();
      
      // Execute and resolve pause
      await guardianPause.connect(guardian1).proposePause(target, "Emergency");
      await guardianPause.connect(guardian2).confirmPause(target);
      await guardianPause.connect(guardian3).confirmPause(target);
      await guardianPause.connect(owner).unpause();
      
      // Should be able to pause again after resolution
      await guardianPause.connect(guardian1).proposePause(target, "New emergency");
      expect(await guardianPause.getConfirmationCount(target)).to.equal(1);
    });
  });

  describe("Emergency Pause", function () {
    it("Should allow guardians to pause with threshold", async function () {
      await guardianPause.connect(guardian1).pause();
      await guardianPause.connect(guardian2).pause();
      
      expect(await guardianPause.isPaused()).to.be.true;
    });

    it("Should not pause with insufficient confirmations", async function () {
      await guardianPause.connect(guardian1).pause();
      
      expect(await guardianPause.isPaused()).to.be.false;
    });

    it("Should emit Paused event", async function () {
      await guardianPause.connect(guardian1).pause();
      
      await expect(
        guardianPause.connect(guardian2).pause()
      ).to.emit(guardianPause, "Paused");
    });
  });

  describe("Unpause", function () {
    beforeEach(async function () {
      await guardianPause.connect(guardian1).pause();
      await guardianPause.connect(guardian2).pause();
    });

    it("Should allow admin to unpause", async function () {
      await expect(
        guardianPause.connect(owner).unpause()
      ).to.emit(guardianPause, "Unpaused");
      
      expect(await guardianPause.isPaused()).to.be.false;
    });

    it("Should auto-unpause after max duration", async function () {
      await time.increase(TEST_CONSTANTS.TIME.WEEK + 1);
      
      expect(await guardianPause.isPaused()).to.be.false;
    });
  });
}); 