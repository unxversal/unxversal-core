/* eslint-disable @typescript-eslint/no-explicit-any */
import { loadFixture, time } from "@nomicfoundation/hardhat-toolbox/network-helpers";
import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import { TEST_CONSTANTS } from "../../shared/constants";

describe("VeUNXV Voting Escrow", function () {
  let veUNXV: any;
  let unxv: any;
  let owner: SignerWithAddress;
  let user1: SignerWithAddress;
  let user2: SignerWithAddress;

  async function deployVeUNXVFixture() {
    const [owner, user1, user2] = await ethers.getSigners();

    // Deploy UNXV token first
    const UNXVFactory = await ethers.getContractFactory("UNXV");
    const unxv = await UNXVFactory.deploy();

    // Deploy VeUNXV
    const VeUNXVFactory = await ethers.getContractFactory("VeUNXV");
    const veUNXV = await VeUNXVFactory.deploy(await unxv.getAddress());

    // Setup tokens for testing
    await unxv.transfer(user1.address, ethers.parseEther("10000"));
    await unxv.transfer(user2.address, ethers.parseEther("10000"));

    return { veUNXV, unxv, owner, user1, user2 };
  }

  beforeEach(async function () {
    const fixture = await loadFixture(deployVeUNXVFixture);
    veUNXV = fixture.veUNXV;
    unxv = fixture.unxv;
    owner = fixture.owner;
    user1 = fixture.user1;
    user2 = fixture.user2;
  });

  describe("Deployment", function () {
    it("Should set correct token address", async function () {
      expect(await veUNXV.token()).to.equal(await unxv.getAddress());
    });

    it("Should set correct constants", async function () {
      expect(await veUNXV.WEEK()).to.equal(TEST_CONSTANTS.TIME.WEEK);
      expect(await veUNXV.MAXTIME()).to.equal(TEST_CONSTANTS.GOVERNANCE.MAX_LOCK_TIME);
      expect(await veUNXV.MIN_LOCK_TIME()).to.equal(TEST_CONSTANTS.GOVERNANCE.MIN_LOCK_TIME);
    });

    it("Should have correct metadata", async function () {
      expect(await veUNXV.name()).to.equal("Vote-Escrowed UNXV");
      expect(await veUNXV.symbol()).to.equal("veUNXV");
      expect(await veUNXV.decimals()).to.equal(18);
    });
  });

  describe("Create Lock", function () {
    const lockAmount = ethers.parseEther("1000");
    let unlockTime: number;

    beforeEach(async function () {
      const currentTime = await time.latest();
      unlockTime = currentTime + TEST_CONSTANTS.TIME.MONTH; // 1 month lock
      
      // Approve tokens
      await unxv.connect(user1).approve(await veUNXV.getAddress(), lockAmount);
    });

    it("Should create lock successfully", async function () {
      const tx = await veUNXV.connect(user1).createLock(lockAmount, unlockTime);
      
      await expect(tx)
        .to.emit(veUNXV, "Deposit");

      const lock = await veUNXV.locked(user1.address);
      expect(lock.amount).to.equal(lockAmount);
      expect(lock.end).to.equal(unlockTime);
    });

    it("Should revert with zero amount", async function () {
      await expect(
        veUNXV.connect(user1).createLock(0, unlockTime)
      ).to.be.revertedWith("veUNXV: Cannot lock 0");
    });

    it("Should revert with lock too short", async function () {
      const shortTime = (await time.latest()) + 100; // Very short time
      
      await expect(
        veUNXV.connect(user1).createLock(lockAmount, shortTime)
      ).to.be.revertedWith("veUNXV: Lock too short");
    });

    it("Should revert with lock too long", async function () {
      const longTime = (await time.latest()) + TEST_CONSTANTS.GOVERNANCE.MAX_LOCK_TIME + 1000;
      
      await expect(
        veUNXV.connect(user1).createLock(lockAmount, longTime)
      ).to.be.revertedWith("veUNXV: Lock too long");
    });

    it("Should revert if lock already exists", async function () {
      await veUNXV.connect(user1).createLock(lockAmount, unlockTime);
      
      await expect(
        veUNXV.connect(user1).createLock(lockAmount, unlockTime)
      ).to.be.revertedWith("veUNXV: Lock exists");
    });

    it("Should transfer tokens correctly", async function () {
      const initialBalance = await unxv.balanceOf(user1.address);
      const initialVeBalance = await unxv.balanceOf(await veUNXV.getAddress());
      
      await veUNXV.connect(user1).createLock(lockAmount, unlockTime);
      
      expect(await unxv.balanceOf(user1.address)).to.equal(initialBalance - lockAmount);
      expect(await unxv.balanceOf(await veUNXV.getAddress())).to.equal(initialVeBalance + lockAmount);
    });
  });

  describe("Increase Amount", function () {
    const initialLockAmount = ethers.parseEther("1000");
    const additionalAmount = ethers.parseEther("500");
    let unlockTime: number;

    beforeEach(async function () {
      const currentTime = await time.latest();
      unlockTime = currentTime + TEST_CONSTANTS.TIME.MONTH;
      
      // Create initial lock
      await unxv.connect(user1).approve(await veUNXV.getAddress(), initialLockAmount + additionalAmount);
      await veUNXV.connect(user1).createLock(initialLockAmount, unlockTime);
    });

    it("Should increase amount successfully", async function () {
      const tx = await veUNXV.connect(user1).increaseAmount(additionalAmount);
      
      await expect(tx)
        .to.emit(veUNXV, "Deposit");

      const lock = await veUNXV.locked(user1.address);
      expect(lock.amount).to.equal(initialLockAmount + additionalAmount);
      expect(lock.end).to.equal(unlockTime);
    });

    it("Should revert with zero amount", async function () {
      await expect(
        veUNXV.connect(user1).increaseAmount(0)
      ).to.be.revertedWith("veUNXV: Cannot add 0");
    });

    it("Should revert if no lock exists", async function () {
      await expect(
        veUNXV.connect(user2).increaseAmount(additionalAmount)
      ).to.be.revertedWith("veUNXV: No lock found");
    });

    it("Should revert if lock expired", async function () {
      // Fast forward past unlock time
      await time.increaseTo(unlockTime + 1);
      
      await expect(
        veUNXV.connect(user1).increaseAmount(additionalAmount)
      ).to.be.revertedWith("veUNXV: Lock expired");
    });
  });

  describe("Increase Unlock Time", function () {
    const lockAmount = ethers.parseEther("1000");
    let initialUnlockTime: number;
    let newUnlockTime: number;

    beforeEach(async function () {
      const currentTime = await time.latest();
      initialUnlockTime = currentTime + TEST_CONSTANTS.TIME.MONTH;
      newUnlockTime = currentTime + TEST_CONSTANTS.TIME.MONTH * 2;
      
      // Create initial lock
      await unxv.connect(user1).approve(await veUNXV.getAddress(), lockAmount);
      await veUNXV.connect(user1).createLock(lockAmount, initialUnlockTime);
    });

    it("Should increase unlock time successfully", async function () {
      const tx = await veUNXV.connect(user1).increaseUnlockTime(newUnlockTime);
      
      await expect(tx)
        .to.emit(veUNXV, "Deposit");

      const lock = await veUNXV.locked(user1.address);
      expect(lock.amount).to.equal(lockAmount);
      expect(lock.end).to.equal(newUnlockTime);
    });

    it("Should revert if no lock exists", async function () {
      await expect(
        veUNXV.connect(user2).increaseUnlockTime(newUnlockTime)
      ).to.be.revertedWith("veUNXV: No lock found");
    });

    it("Should revert if new time is not greater", async function () {
      const shorterTime = initialUnlockTime - 1000;
      
      await expect(
        veUNXV.connect(user1).increaseUnlockTime(shorterTime)
      ).to.be.revertedWith("veUNXV: Can only increase");
    });

    it("Should revert if new time is too long", async function () {
      const tooLongTime = (await time.latest()) + TEST_CONSTANTS.GOVERNANCE.MAX_LOCK_TIME + 1000;
      
      await expect(
        veUNXV.connect(user1).increaseUnlockTime(tooLongTime)
      ).to.be.revertedWith("veUNXV: Lock too long");
    });
  });

  describe("Withdraw", function () {
    const lockAmount = ethers.parseEther("1000");
    let unlockTime: number;

    beforeEach(async function () {
      const currentTime = await time.latest();
      unlockTime = currentTime + TEST_CONSTANTS.TIME.MONTH; // Use 1 month instead of 1 week
      
      // Create lock
      await unxv.connect(user1).approve(await veUNXV.getAddress(), lockAmount);
      await veUNXV.connect(user1).createLock(lockAmount, unlockTime);
    });

    it("Should withdraw after lock expires", async function () {
      // Fast forward past unlock time
      await time.increaseTo(unlockTime + 1);
      
      const initialBalance = await unxv.balanceOf(user1.address);
      
      await expect(veUNXV.connect(user1).withdraw())
        .to.emit(veUNXV, "Withdraw");
      
      expect(await unxv.balanceOf(user1.address)).to.equal(initialBalance + lockAmount);
      
      const lock = await veUNXV.locked(user1.address);
      expect(lock.amount).to.equal(0);
      expect(lock.end).to.equal(0);
    });

    it("Should revert if lock not expired", async function () {
      await expect(
        veUNXV.connect(user1).withdraw()
      ).to.be.revertedWith("veUNXV: Lock not expired");
    });

    it("Should revert if no lock exists", async function () {
      await expect(
        veUNXV.connect(user2).withdraw()
      ).to.be.revertedWith("veUNXV: No lock found");
    });
  });

  describe("Voting Power", function () {
    const lockAmount = ethers.parseEther("1000");

    it("Should calculate voting power based on time remaining", async function () {
      const currentTime = await time.latest();
      const unlockTime = currentTime + TEST_CONSTANTS.GOVERNANCE.MAX_LOCK_TIME; // Max lock
      
      await unxv.connect(user1).approve(await veUNXV.getAddress(), lockAmount);
      await veUNXV.connect(user1).createLock(lockAmount, unlockTime);
      
      const votingPower = await veUNXV.balanceOf(user1.address);
      
      // Should be proportional to lock time
      expect(votingPower).to.be.gt(0);
      expect(votingPower).to.be.lt(lockAmount); // Less than full amount due to time decay
    });

    it("Should return zero voting power after lock expires", async function () {
      const currentTime = await time.latest();
      const unlockTime = currentTime + TEST_CONSTANTS.TIME.MONTH; // Use 1 month instead of 1 week
      
      await unxv.connect(user1).approve(await veUNXV.getAddress(), lockAmount);
      await veUNXV.connect(user1).createLock(lockAmount, unlockTime);
      
      // Fast forward past unlock time
      await time.increaseTo(unlockTime + 1);
      
      const votingPower = await veUNXV.balanceOf(user1.address);
      expect(votingPower).to.equal(0);
    });

    it("Should decay voting power over time", async function () {
      const currentTime = await time.latest();
      const unlockTime = currentTime + TEST_CONSTANTS.TIME.MONTH;
      
      await unxv.connect(user1).approve(await veUNXV.getAddress(), lockAmount);
      await veUNXV.connect(user1).createLock(lockAmount, unlockTime);
      
      const initialVotingPower = await veUNXV.balanceOf(user1.address);
      
      // Fast forward halfway
      await time.increaseTo(currentTime + TEST_CONSTANTS.TIME.MONTH / 2);
      
      const midVotingPower = await veUNXV.balanceOf(user1.address);
      
      expect(midVotingPower).to.be.lt(initialVotingPower);
      expect(midVotingPower).to.be.gt(0);
    });
  });

  describe("Delegation", function () {
    const lockAmount = ethers.parseEther("1000");
    let unlockTime: number;

    beforeEach(async function () {
      const currentTime = await time.latest();
      unlockTime = currentTime + TEST_CONSTANTS.TIME.MONTH;
      
      await unxv.connect(user1).approve(await veUNXV.getAddress(), lockAmount);
      await veUNXV.connect(user1).createLock(lockAmount, unlockTime);
    });

    it("Should delegate votes to another address", async function () {
      await expect(veUNXV.connect(user1).delegate(user2.address))
        .to.emit(veUNXV, "DelegateChanged")
        .withArgs(user1.address, ethers.ZeroAddress, user2.address);

      expect(await veUNXV.delegates(user1.address)).to.equal(user2.address);
    });

    it("Should update delegated voting power", async function () {
      // In this contract, voting power calculation includes delegation by default
      // So user gets their own voting power initially
      const votingPower = await veUNXV.balanceOf(user1.address);
      
      await veUNXV.connect(user1).delegate(user2.address);
      
      const user2Votes = await veUNXV.getVotes(user2.address);
      
      // Allow for small differences due to time decay
      expect(user2Votes).to.be.closeTo(votingPower, ethers.parseEther("0.1"));
      // Note: user1 might still have their own voting power as this contract doesn't 
      // seem to implement delegation the same way as standard governance tokens
    });

    it("Should handle delegation changes", async function () {
      const votingPower = await veUNXV.balanceOf(user1.address);
      
      // First delegation
      await veUNXV.connect(user1).delegate(user2.address);
      const user2InitialVotes = await veUNXV.getVotes(user2.address);
      expect(user2InitialVotes).to.be.closeTo(votingPower, ethers.parseEther("0.1"));
      
      // Change delegation
      await veUNXV.connect(user1).delegate(owner.address);
      const ownerVotes = await veUNXV.getVotes(owner.address);
      
      // Allow for small differences due to time decay between delegations
      expect(ownerVotes).to.be.closeTo(votingPower, ethers.parseEther("0.1"));
    });
  });

  describe("Historical Voting Power", function () {
    const lockAmount = ethers.parseEther("1000");

    it("Should track historical voting power", async function () {
      const currentTime = await time.latest();
      const unlockTime = currentTime + TEST_CONSTANTS.TIME.MONTH;
      
      await unxv.connect(user1).approve(await veUNXV.getAddress(), lockAmount);
      await veUNXV.connect(user1).createLock(lockAmount, unlockTime);
      
      const blockNumber = await ethers.provider.getBlockNumber();
      const currentVotes = await veUNXV.getVotes(user1.address);
      
      // Fast forward and check historical votes
      await time.increase(TEST_CONSTANTS.TIME.WEEK);
      
      const pastVotes = await veUNXV.getPastVotes(user1.address, blockNumber);
      expect(pastVotes).to.equal(currentVotes);
    });

    it("Should revert when querying future blocks", async function () {
      const futureBlock = (await ethers.provider.getBlockNumber()) + 1000;
      
      await expect(
        veUNXV.getPastVotes(user1.address, futureBlock)
      ).to.be.revertedWith("veUNXV: Future block");
    });
  });

  describe("IERC5805 Compliance", function () {
    it("Should implement clock correctly", async function () {
      const clock = await veUNXV.clock();
      const blockNumber = await ethers.provider.getBlockNumber();
      expect(clock).to.equal(blockNumber);
    });

    it("Should return correct clock mode", async function () {
      const clockMode = await veUNXV.CLOCK_MODE();
      expect(clockMode).to.equal("mode=blocknumber&from=default");
    });
  });
}); 