/* eslint-disable @typescript-eslint/no-explicit-any */
/* eslint-disable @typescript-eslint/no-unused-expressions */
import { loadFixture } from "@nomicfoundation/hardhat-toolbox/network-helpers";
import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";
import { TEST_CONSTANTS } from "../../shared/constants";

describe("UNXV Token", function () {
  let unxv: any;
  let owner: SignerWithAddress;
  let user1: SignerWithAddress;
  let user2: SignerWithAddress;

  async function deployUNXVFixture() {
    const [owner, user1, user2] = await ethers.getSigners();

    const UNXVFactory = await ethers.getContractFactory("UNXV");
    const unxv = await UNXVFactory.deploy();

    return { unxv, owner, user1, user2 };
  }

  beforeEach(async function () {
    const fixture = await loadFixture(deployUNXVFixture);
    unxv = fixture.unxv;
    owner = fixture.owner;
    user1 = fixture.user1;
    user2 = fixture.user2;
  });

  describe("Deployment", function () {
    it("Should set the correct name and symbol", async function () {
      expect(await unxv.name()).to.equal("unxversal");
      expect(await unxv.symbol()).to.equal("UNXV");
    });

    it("Should set the correct decimals", async function () {
      expect(await unxv.decimals()).to.equal(18);
    });

    it("Should assign initial supply to owner", async function () {
      const totalSupply = await unxv.totalSupply();
      const ownerBalance = await unxv.balanceOf(owner.address);
      const expectedSupply = ethers.parseEther("1000000000"); // 1 billion tokens
      
      expect(ownerBalance).to.equal(totalSupply);
      expect(totalSupply).to.equal(expectedSupply);
    });

    it("Should set owner as contract owner", async function () {
      expect(await unxv.owner()).to.equal(owner.address);
    });

    it("Should not have minting finished initially", async function () {
      expect(await unxv.mintingFinished()).to.be.false;
    });
  });

  describe("Minting Control", function () {
    it("Should allow owner to finish minting", async function () {
      await unxv.finishMinting();
      expect(await unxv.mintingFinished()).to.be.true;
    });

    it("Should emit MintingFinished event", async function () {
      await expect(unxv.finishMinting())
        .to.emit(unxv, "MintingFinished");
    });

    it("Should revert if non-owner tries to finish minting", async function () {
      await expect(
        unxv.connect(user1).finishMinting()
      ).to.be.revertedWithCustomError(unxv, "OwnableUnauthorizedAccount");
    });

    it("Should revert if minting is already finished", async function () {
      await unxv.finishMinting();
      
      // After finishing minting, ownership is renounced, so subsequent calls fail due to ownership
      await expect(
        unxv.finishMinting()
      ).to.be.revertedWithCustomError(unxv, "OwnableUnauthorizedAccount");
    });

    it("Should renounce ownership after finishing minting", async function () {
      await unxv.finishMinting();
      expect(await unxv.owner()).to.equal(ethers.ZeroAddress);
    });
  });

  describe("EIP-2612 Permit", function () {
    it("Should have correct domain separator", async function () {
      const domainSeparator = await unxv.DOMAIN_SEPARATOR();
      expect(domainSeparator).to.not.equal(ethers.ZeroHash);
    });

    it("Should allow permit functionality", async function () {
      const value = ethers.parseEther("100");
      const nonce = await unxv.nonces(owner.address);
      const deadline = Math.floor(Date.now() / 1000) + 3600; // 1 hour from now
      
      // Create permit signature
      const domain = {
        name: await unxv.name(),
        version: "1",
        chainId: await ethers.provider.getNetwork().then(n => n.chainId),
        verifyingContract: await unxv.getAddress()
      };
      
      const types = {
        Permit: [
          { name: "owner", type: "address" },
          { name: "spender", type: "address" },
          { name: "value", type: "uint256" },
          { name: "nonce", type: "uint256" },
          { name: "deadline", type: "uint256" }
        ]
      };
      
      const values = {
        owner: owner.address,
        spender: user1.address,
        value: value,
        nonce: nonce,
        deadline: deadline
      };
      
      const signature = await owner.signTypedData(domain, types, values);
      const { v, r, s } = ethers.Signature.from(signature);
      
      // Execute permit
      await unxv.permit(owner.address, user1.address, value, deadline, v, r, s);
      
      expect(await unxv.allowance(owner.address, user1.address)).to.equal(value);
    });
  });

  describe("Transfers", function () {
    beforeEach(async function () {
      // Transfer some tokens to user1 for testing
      await unxv.transfer(user1.address, ethers.parseEther("1000"));
    });

    it("Should transfer tokens between accounts", async function () {
      const transferAmount = ethers.parseEther("100");
      const initialUser1Balance = await unxv.balanceOf(user1.address);
      const initialUser2Balance = await unxv.balanceOf(user2.address);
      
      await unxv.connect(user1).transfer(user2.address, transferAmount);
      
      expect(await unxv.balanceOf(user1.address)).to.equal(
        initialUser1Balance - transferAmount
      );
      expect(await unxv.balanceOf(user2.address)).to.equal(
        initialUser2Balance + transferAmount
      );
    });

    it("Should revert transfer with insufficient balance", async function () {
      const transferAmount = ethers.parseEther("10000"); // More than user1 has
      
      await expect(
        unxv.connect(user1).transfer(user2.address, transferAmount)
      ).to.be.revertedWithCustomError(unxv, "ERC20InsufficientBalance");
    });

    it("Should handle transferFrom with allowance", async function () {
      const transferAmount = ethers.parseEther("100");
      
      // Approve user2 to spend user1's tokens
      await unxv.connect(user1).approve(user2.address, transferAmount);
      
      const initialUser1Balance = await unxv.balanceOf(user1.address);
      const initialOwnerBalance = await unxv.balanceOf(owner.address);
      
      // user2 transfers from user1 to owner
      await unxv.connect(user2).transferFrom(user1.address, owner.address, transferAmount);
      
      expect(await unxv.balanceOf(user1.address)).to.equal(
        initialUser1Balance - transferAmount
      );
      expect(await unxv.balanceOf(owner.address)).to.equal(
        initialOwnerBalance + transferAmount
      );
      expect(await unxv.allowance(user1.address, user2.address)).to.equal(0);
    });
  });

  describe("Events", function () {
    it("Should emit Transfer event on transfer", async function () {
      const transferAmount = ethers.parseEther("100");
      
      await expect(unxv.transfer(user1.address, transferAmount))
        .to.emit(unxv, "Transfer")
        .withArgs(owner.address, user1.address, transferAmount);
    });

    it("Should emit Approval event on approve", async function () {
      const approveAmount = ethers.parseEther("100");
      
      await expect(unxv.approve(user1.address, approveAmount))
        .to.emit(unxv, "Approval")
        .withArgs(owner.address, user1.address, approveAmount);
    });
  });
}); 