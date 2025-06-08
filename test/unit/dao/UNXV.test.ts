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
    const unxv = await UNXVFactory.deploy(owner.address);

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
      expect(await unxv.name()).to.equal("Unxversal Token");
      expect(await unxv.symbol()).to.equal("UNXV");
    });

    it("Should set the correct decimals", async function () {
      expect(await unxv.decimals()).to.equal(18);
    });

    it("Should assign initial supply to owner", async function () {
      const totalSupply = await unxv.totalSupply();
      const ownerBalance = await unxv.balanceOf(owner.address);
      expect(ownerBalance).to.equal(totalSupply);
      expect(totalSupply).to.equal(TEST_CONSTANTS.TOKENS.INITIAL_SUPPLY);
    });

    it("Should set owner as initial admin", async function () {
      const DEFAULT_ADMIN_ROLE = await unxv.DEFAULT_ADMIN_ROLE();
      expect(await unxv.hasRole(DEFAULT_ADMIN_ROLE, owner.address)).to.be.true;
    });
  });

  describe("Minting", function () {
    it("Should allow minter to mint tokens", async function () {
      const MINTER_ROLE = await unxv.MINTER_ROLE();
      await unxv.grantRole(MINTER_ROLE, owner.address);
      
      const mintAmount = ethers.parseEther("1000");
      const initialSupply = await unxv.totalSupply();
      
      await unxv.mint(user1.address, mintAmount);
      
      expect(await unxv.balanceOf(user1.address)).to.equal(mintAmount);
      expect(await unxv.totalSupply()).to.equal(initialSupply + mintAmount);
    });

    it("Should revert if non-minter tries to mint", async function () {
      const mintAmount = ethers.parseEther("1000");
      
      await expect(
        unxv.connect(user1).mint(user1.address, mintAmount)
      ).to.be.revertedWith("UNXV: Caller is not a minter");
    });

    it("Should allow admin to grant minter role", async function () {
      const MINTER_ROLE = await unxv.MINTER_ROLE();
      
      await unxv.grantRole(MINTER_ROLE, user1.address);
      
      expect(await unxv.hasRole(MINTER_ROLE, user1.address)).to.be.true;
    });
  });

  describe("Minting Controls", function () {
    it("Should allow admin to disable minting", async function () {
      await unxv.disableMinting();
      expect(await unxv.mintingDisabled()).to.be.true;
    });

    it("Should revert minting when disabled", async function () {
      const MINTER_ROLE = await unxv.MINTER_ROLE();
      await unxv.grantRole(MINTER_ROLE, owner.address);
      await unxv.disableMinting();
      
      const mintAmount = ethers.parseEther("1000");
      
      await expect(
        unxv.mint(user1.address, mintAmount)
      ).to.be.revertedWith("UNXV: Minting disabled");
    });

    it("Should revert if non-admin tries to disable minting", async function () {
      await expect(
        unxv.connect(user1).disableMinting()
      ).to.be.revertedWith("AccessControl:");
    });

    it("Should not allow re-enabling minting once disabled", async function () {
      await unxv.disableMinting();
      
      // There should be no function to re-enable minting
      expect(unxv.enableMinting).to.be.undefined;
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
      ).to.be.revertedWith("ERC20: transfer amount exceeds balance");
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

  describe("Access Control", function () {
    it("Should allow admin to grant roles", async function () {
      const MINTER_ROLE = await unxv.MINTER_ROLE();
      
      await unxv.grantRole(MINTER_ROLE, user1.address);
      
      expect(await unxv.hasRole(MINTER_ROLE, user1.address)).to.be.true;
    });

    it("Should allow admin to revoke roles", async function () {
      const MINTER_ROLE = await unxv.MINTER_ROLE();
      
      await unxv.grantRole(MINTER_ROLE, user1.address);
      await unxv.revokeRole(MINTER_ROLE, user1.address);
      
      expect(await unxv.hasRole(MINTER_ROLE, user1.address)).to.be.false;
    });

    it("Should not allow non-admin to grant roles", async function () {
      const MINTER_ROLE = await unxv.MINTER_ROLE();
      
      await expect(
        unxv.connect(user1).grantRole(MINTER_ROLE, user2.address)
      ).to.be.revertedWith("AccessControl:");
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

    it("Should emit RoleGranted event when granting role", async function () {
      const MINTER_ROLE = await unxv.MINTER_ROLE();
      
      await expect(unxv.grantRole(MINTER_ROLE, user1.address))
        .to.emit(unxv, "RoleGranted")
        .withArgs(MINTER_ROLE, user1.address, owner.address);
    });
  });
}); 