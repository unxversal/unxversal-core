/* eslint-disable @typescript-eslint/no-explicit-any */
/* eslint-disable @typescript-eslint/no-unused-expressions */
/* eslint-disable @typescript-eslint/no-unused-vars */
import { loadFixture, time } from "@nomicfoundation/hardhat-toolbox/network-helpers";
import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import { TEST_CONSTANTS } from "../../shared/constants";

describe("UnxversalGovernor", function () {
  let governor: any;
  let unxv: any;
  let veUNXV: any;
  let timelock: any;
  let mockTarget: any;
  let owner: SignerWithAddress;
  let proposer: SignerWithAddress;
  let voter1: SignerWithAddress;
  let voter2: SignerWithAddress;
  let executor: SignerWithAddress;

  async function deployGovernorFixture() {
    const [owner, proposer, voter1, voter2, executor] = await ethers.getSigners();

    // Deploy UNXV token
    const UNXVFactory = await ethers.getContractFactory("UNXV");
    const unxv = await UNXVFactory.deploy();

    // Deploy VeUNXV
    const VeUNXVFactory = await ethers.getContractFactory("VeUNXV");
    const veUNXV = await VeUNXVFactory.deploy(await unxv.getAddress());

    // Deploy TimelockController
    const TimelockFactory = await ethers.getContractFactory("TimelockController");
    const timelock = await TimelockFactory.deploy(
      TEST_CONSTANTS.GOVERNANCE.TIMELOCK_DELAY,
      [owner.address], // proposers
      [owner.address], // executors
      owner.address    // admin
    );

    // Deploy UnxversalGovernor
    const GovernorFactory = await ethers.getContractFactory("UnxversalGovernor");
    const governor = await GovernorFactory.deploy(
      await veUNXV.getAddress(), // IVotes _token (should be veUNXV)
      await timelock.getAddress(), // TimelockController _timelock
      TEST_CONSTANTS.GOVERNANCE.VOTING_DELAY, // uint256 _votingDelay
      TEST_CONSTANTS.GOVERNANCE.VOTING_PERIOD, // uint256 _votingPeriod
      TEST_CONSTANTS.GOVERNANCE.PROPOSAL_THRESHOLD, // uint256 _proposalThreshold
      TEST_CONSTANTS.GOVERNANCE.QUORUM // uint256 _quorumPercentage
    );

    // Deploy mock target contract for testing
    const MockERC20Factory = await ethers.getContractFactory("MockERC20");
    const mockTarget = await MockERC20Factory.deploy("Target", "TGT", 18, 0);

    // Setup governance roles
    await timelock.grantRole(await timelock.PROPOSER_ROLE(), await governor.getAddress());
    await timelock.grantRole(await timelock.EXECUTOR_ROLE(), await governor.getAddress());

    // Distribute tokens and create locks for voting power
    const lockAmount = ethers.parseEther("100000");
    const lockDuration = Math.floor(Date.now() / 1000) + TEST_CONSTANTS.GOVERNANCE.MAX_LOCK_TIME;

    // Setup proposer
    await (unxv as any).transfer(proposer.address, lockAmount);
    await (unxv as any).connect(proposer).approve(await veUNXV.getAddress(), lockAmount);
    await (veUNXV as any).connect(proposer).createLock(lockAmount, lockDuration);

    // Setup voters
    await (unxv as any).transfer(voter1.address, lockAmount);
    await (unxv as any).connect(voter1).approve(await veUNXV.getAddress(), lockAmount);
    await (veUNXV as any).connect(voter1).createLock(lockAmount, lockDuration);

    await (unxv as any).transfer(voter2.address, lockAmount);
    await (unxv as any).connect(voter2).approve(await veUNXV.getAddress(), lockAmount);
    await (veUNXV as any).connect(voter2).createLock(lockAmount, lockDuration);

    return {
      governor,
      unxv,
      veUNXV,
      timelock,
      mockTarget,
      owner,
      proposer,
      voter1,
      voter2,
      executor
    };
  }

  beforeEach(async function () {
    const fixture = await loadFixture(deployGovernorFixture);
    governor = fixture.governor;
    unxv = fixture.unxv;
    veUNXV = fixture.veUNXV;
    timelock = fixture.timelock;
    mockTarget = fixture.mockTarget;
    owner = fixture.owner;
    proposer = fixture.proposer;
    voter1 = fixture.voter1;
    voter2 = fixture.voter2;
    executor = fixture.executor;
  });

  describe("Initialization", function () {
    it("Should set correct token address", async function () {
      expect(await governor.token()).to.equal(await unxv.getAddress());
    });

    it("Should set correct voting escrow", async function () {
      expect(await governor.veToken()).to.equal(await veUNXV.getAddress());
    });

    it("Should set correct timelock", async function () {
      expect(await governor.timelock()).to.equal(await timelock.getAddress());
    });

    it("Should set correct voting period", async function () {
      expect(await governor.votingPeriod()).to.equal(TEST_CONSTANTS.GOVERNANCE.VOTING_PERIOD);
    });

    it("Should set correct proposal threshold", async function () {
      expect(await governor.proposalThreshold()).to.equal(TEST_CONSTANTS.GOVERNANCE.PROPOSAL_THRESHOLD);
    });
  });

  describe("Proposal Creation", function () {
    it("Should create proposal with sufficient voting power", async function () {
      const targets = [await mockTarget.getAddress()];
      const values = [0];
      const calldatas = [mockTarget.interface.encodeFunctionData("mint", [proposer.address, ethers.parseEther("1000")])];
      const description = "Mint 1000 tokens to proposer";

      await expect(
        governor.connect(proposer).propose(targets, values, calldatas, description)
      ).to.emit(governor, "ProposalCreated");
    });

    it("Should not allow proposal with insufficient voting power", async function () {
      const targets = [await mockTarget.getAddress()];
      const values = [0];
      const calldatas = [mockTarget.interface.encodeFunctionData("mint", [owner.address, ethers.parseEther("1000")])];
      const description = "Mint 1000 tokens";

      await expect(
        governor.connect(owner).propose(targets, values, calldatas, description)
      ).to.be.revertedWith("Governor: proposer votes below proposal threshold");
    });

    it("Should calculate proposal ID correctly", async function () {
      const targets = [await mockTarget.getAddress()];
      const values = [0];
      const calldatas = [mockTarget.interface.encodeFunctionData("mint", [proposer.address, ethers.parseEther("1000")])];
      const description = "Mint 1000 tokens to proposer";

      const expectedId = await governor.hashProposal(targets, values, calldatas, ethers.keccak256(ethers.toUtf8Bytes(description)));
      
      const tx = await governor.connect(proposer).propose(targets, values, calldatas, description);
      const receipt = await tx.wait();
      const event = receipt.logs.find((log: any) => log.fragment?.name === "ProposalCreated");
      
      expect(event.args[0]).to.equal(expectedId);
    });
  });

  describe("Voting", function () {
    let proposalId: any;

    beforeEach(async function () {
      const targets = [await mockTarget.getAddress()];
      const values = [0];
      const calldatas = [mockTarget.interface.encodeFunctionData("mint", [proposer.address, ethers.parseEther("1000")])];
      const description = "Mint 1000 tokens to proposer";

      const tx = await governor.connect(proposer).propose(targets, values, calldatas, description);
      const receipt = await tx.wait();
      const event = receipt.logs.find((log: any) => log.fragment?.name === "ProposalCreated");
      proposalId = event.args[0];

      // Move to voting period
      await time.increase(TEST_CONSTANTS.GOVERNANCE.VOTING_DELAY);
    });

    it("Should allow voting for proposal", async function () {
      await expect(
        governor.connect(voter1).castVote(proposalId, 1) // Vote FOR
      ).to.emit(governor, "VoteCast");
    });

    it("Should allow voting against proposal", async function () {
      await expect(
        governor.connect(voter1).castVote(proposalId, 0) // Vote AGAINST
      ).to.emit(governor, "VoteCast");
    });

    it("Should allow abstaining", async function () {
      await expect(
        governor.connect(voter1).castVote(proposalId, 2) // ABSTAIN
      ).to.emit(governor, "VoteCast");
    });

    it("Should weight votes by veUNXV balance", async function () {
      await governor.connect(voter1).castVote(proposalId, 1);
      
      const proposalVotes = await governor.proposalVotes(proposalId);
      const voterWeight = await veUNXV.balanceOf(voter1.address);
      
      expect(proposalVotes.forVotes).to.equal(voterWeight);
    });

    it("Should not allow double voting", async function () {
      await governor.connect(voter1).castVote(proposalId, 1);
      
      await expect(
        governor.connect(voter1).castVote(proposalId, 1)
      ).to.be.revertedWith("Governor: vote already cast");
    });

    it("Should not allow voting outside voting period", async function () {
      await time.increase(TEST_CONSTANTS.GOVERNANCE.VOTING_PERIOD + 1);
      
      await expect(
        governor.connect(voter1).castVote(proposalId, 1)
      ).to.be.revertedWith("Governor: vote not currently active");
    });
  });

  describe("Proposal States", function () {
    let proposalId: any;

    beforeEach(async function () {
      const targets = [await mockTarget.getAddress()];
      const values = [0];
      const calldatas = [mockTarget.interface.encodeFunctionData("mint", [proposer.address, ethers.parseEther("1000")])];
      const description = "Mint 1000 tokens to proposer";

      const tx = await governor.connect(proposer).propose(targets, values, calldatas, description);
      const receipt = await tx.wait();
      const event = receipt.logs.find((log: any) => log.fragment?.name === "ProposalCreated");
      proposalId = event.args[0];
    });

    it("Should start in Pending state", async function () {
      expect(await governor.state(proposalId)).to.equal(0); // Pending
    });

    it("Should move to Active after voting delay", async function () {
      await time.increase(TEST_CONSTANTS.GOVERNANCE.VOTING_DELAY);
      expect(await governor.state(proposalId)).to.equal(1); // Active
    });

    it("Should move to Succeeded with enough FOR votes", async function () {
      await time.increase(TEST_CONSTANTS.GOVERNANCE.VOTING_DELAY);
      
      // Vote with majority
      await governor.connect(voter1).castVote(proposalId, 1);
      await governor.connect(voter2).castVote(proposalId, 1);
      
      await time.increase(TEST_CONSTANTS.GOVERNANCE.VOTING_PERIOD);
      expect(await governor.state(proposalId)).to.equal(4); // Succeeded
    });

    it("Should move to Defeated without enough votes", async function () {
      await time.increase(TEST_CONSTANTS.GOVERNANCE.VOTING_DELAY);
      
      // Vote against or insufficient votes
      await governor.connect(voter1).castVote(proposalId, 0);
      
      await time.increase(TEST_CONSTANTS.GOVERNANCE.VOTING_PERIOD);
      expect(await governor.state(proposalId)).to.equal(3); // Defeated
    });
  });

  describe("Proposal Execution", function () {
    let proposalId: any;
    let targets: string[];
    let values: number[];
    let calldatas: string[];
    let description: string;

    beforeEach(async function () {
      targets = [await mockTarget.getAddress()];
      values = [0];
      calldatas = [mockTarget.interface.encodeFunctionData("mint", [proposer.address, ethers.parseEther("1000")])];
      description = "Mint 1000 tokens to proposer";

      const tx = await governor.connect(proposer).propose(targets, values, calldatas, description);
      const receipt = await tx.wait();
      const event = receipt.logs.find((log: any) => log.fragment?.name === "ProposalCreated");
      proposalId = event.args[0];

      // Vote and pass proposal
      await time.increase(TEST_CONSTANTS.GOVERNANCE.VOTING_DELAY);
      await governor.connect(voter1).castVote(proposalId, 1);
      await governor.connect(voter2).castVote(proposalId, 1);
      await time.increase(TEST_CONSTANTS.GOVERNANCE.VOTING_PERIOD);
    });

    it("Should queue successful proposal", async function () {
      await expect(
        governor.queue(targets, values, calldatas, ethers.keccak256(ethers.toUtf8Bytes(description)))
      ).to.emit(governor, "ProposalQueued");
      
      expect(await governor.state(proposalId)).to.equal(5); // Queued
    });

    it("Should execute queued proposal after timelock delay", async function () {
      await governor.queue(targets, values, calldatas, ethers.keccak256(ethers.toUtf8Bytes(description)));
      
      await time.increase(TEST_CONSTANTS.GOVERNANCE.TIMELOCK_DELAY);
      
      const initialBalance = await mockTarget.balanceOf(proposer.address);
      
      await expect(
        governor.execute(targets, values, calldatas, ethers.keccak256(ethers.toUtf8Bytes(description)))
      ).to.emit(governor, "ProposalExecuted");
      
      expect(await mockTarget.balanceOf(proposer.address)).to.equal(
        initialBalance + ethers.parseEther("1000")
      );
      expect(await governor.state(proposalId)).to.equal(7); // Executed
    });

    it("Should not execute before timelock delay", async function () {
      await governor.queue(targets, values, calldatas, ethers.keccak256(ethers.toUtf8Bytes(description)));
      
      await expect(
        governor.execute(targets, values, calldatas, ethers.keccak256(ethers.toUtf8Bytes(description)))
      ).to.be.revertedWith("TimelockController: operation is not ready");
    });
  });

  describe("Quorum", function () {
    it("Should calculate quorum correctly", async function () {
      const totalSupply = await veUNXV.totalSupply();
      const expectedQuorum = (totalSupply * BigInt(TEST_CONSTANTS.GOVERNANCE.QUORUM)) / BigInt(10000);
      
      expect(await governor.quorum(await time.latest())).to.equal(expectedQuorum);
    });

    it("Should require quorum for proposal success", async function () {
      // Create a proposal with insufficient participation
      const targets = [await mockTarget.getAddress()];
      const values = [0];
      const calldatas = [mockTarget.interface.encodeFunctionData("mint", [proposer.address, ethers.parseEther("1000")])];
      const description = "Mint 1000 tokens to proposer";

      const tx = await governor.connect(proposer).propose(targets, values, calldatas, description);
      const receipt = await tx.wait();
      const event = receipt.logs.find((log: any) => log.fragment?.name === "ProposalCreated");
      const proposalId = event.args[0];

      await time.increase(TEST_CONSTANTS.GOVERNANCE.VOTING_DELAY);
      
      // Only one voter (insufficient for quorum)
      await governor.connect(voter1).castVote(proposalId, 1);
      
      await time.increase(TEST_CONSTANTS.GOVERNANCE.VOTING_PERIOD);
      
      // Should be defeated due to insufficient quorum
      expect(await governor.state(proposalId)).to.equal(3); // Defeated
    });
  });

  describe("Parameter Updates", function () {
    it("Should update voting delay through governance", async function () {
      const newDelay = 2;
      const targets = [await governor.getAddress()];
      const values = [0];
      const calldatas = [governor.interface.encodeFunctionData("setVotingDelay", [newDelay])];
      const description = "Update voting delay";

      // Propose and execute parameter change
      const tx = await governor.connect(proposer).propose(targets, values, calldatas, description);
      const receipt = await tx.wait();
      const event = receipt.logs.find((log: any) => log.fragment?.name === "ProposalCreated");
      const proposalId = event.args[0];

      await time.increase(TEST_CONSTANTS.GOVERNANCE.VOTING_DELAY);
      await governor.connect(voter1).castVote(proposalId, 1);
      await governor.connect(voter2).castVote(proposalId, 1);
      await time.increase(TEST_CONSTANTS.GOVERNANCE.VOTING_PERIOD);

      await governor.queue(targets, values, calldatas, ethers.keccak256(ethers.toUtf8Bytes(description)));
      await time.increase(TEST_CONSTANTS.GOVERNANCE.TIMELOCK_DELAY);
      await governor.execute(targets, values, calldatas, ethers.keccak256(ethers.toUtf8Bytes(description)));

      expect(await governor.votingDelay()).to.equal(newDelay);
    });
  });

  describe("Integration Scenarios", function () {
    it("Should handle complex multi-target proposal", async function () {
      const targets = [
        await mockTarget.getAddress(),
        await mockTarget.getAddress()
      ];
      const values = [0, 0];
      const calldatas = [
        mockTarget.interface.encodeFunctionData("mint", [voter1.address, ethers.parseEther("500")]),
        mockTarget.interface.encodeFunctionData("mint", [voter2.address, ethers.parseEther("500")])
      ];
      const description = "Mint tokens to multiple users";

      const tx = await governor.connect(proposer).propose(targets, values, calldatas, description);
      const receipt = await tx.wait();
      const event = receipt.logs.find((log: any) => log.fragment?.name === "ProposalCreated");
      const proposalId = event.args[0];

      await time.increase(TEST_CONSTANTS.GOVERNANCE.VOTING_DELAY);
      await governor.connect(voter1).castVote(proposalId, 1);
      await governor.connect(voter2).castVote(proposalId, 1);
      await time.increase(TEST_CONSTANTS.GOVERNANCE.VOTING_PERIOD);

      await governor.queue(targets, values, calldatas, ethers.keccak256(ethers.toUtf8Bytes(description)));
      await time.increase(TEST_CONSTANTS.GOVERNANCE.TIMELOCK_DELAY);
      await governor.execute(targets, values, calldatas, ethers.keccak256(ethers.toUtf8Bytes(description)));

      expect(await mockTarget.balanceOf(voter1.address)).to.equal(ethers.parseEther("500"));
      expect(await mockTarget.balanceOf(voter2.address)).to.equal(ethers.parseEther("500"));
    });
  });
}); 