/* eslint-disable @typescript-eslint/no-explicit-any */
/* eslint-disable @typescript-eslint/no-unused-expressions */
import { loadFixture } from "@nomicfoundation/hardhat-toolbox/network-helpers";
import { expect } from "chai";
import { ethers } from "hardhat";
import { SignerWithAddress } from "@nomicfoundation/hardhat-ethers/signers";

describe("SynthToken", function () {
  let synthToken: any;
  let factory: SignerWithAddress;
  let user1: SignerWithAddress;
  let user2: SignerWithAddress;
  let unauthorized: SignerWithAddress;

  async function deploySynthTokenFixture() {
    const [factory, user1, user2, unauthorized] = await ethers.getSigners();

    // Deploy SynthToken
    const SynthTokenFactory = await ethers.getContractFactory("SynthToken");
    const synthToken = await SynthTokenFactory.deploy(
      "Synthetic ETH",
      "sETH",
      factory.address // Factory is the admin
    );

    // Grant MINTER_ROLE and BURNER_ROLE to factory
    const minterRole = await synthToken.MINTER_ROLE();
    const burnerRole = await synthToken.BURNER_ROLE();
    await synthToken.connect(factory).grantRole(minterRole, factory.address);
    await synthToken.connect(factory).grantRole(burnerRole, factory.address);

    return {
      synthToken,
      factory,
      user1,
      user2,
      unauthorized
    };
  }

  beforeEach(async function () {
    const fixture = await loadFixture(deploySynthTokenFixture);
    synthToken = fixture.synthToken;
    factory = fixture.factory;
    user1 = fixture.user1;
    user2 = fixture.user2;
    unauthorized = fixture.unauthorized;
  });

  describe("Deployment", function () {
    it("Should set correct name", async function () {
      expect(await synthToken.name()).to.equal("Synthetic ETH");
    });

    it("Should set correct symbol", async function () {
      expect(await synthToken.symbol()).to.equal("sETH");
    });

    it("Should set correct decimals", async function () {
      expect(await synthToken.decimals()).to.equal(18);
    });

    it("Should set factory as minter", async function () {
      expect(await synthToken.hasRole(await synthToken.MINTER_ROLE(), factory.address)).to.be.true;
    });

    it("Should have zero total supply initially", async function () {
      expect(await synthToken.totalSupply()).to.equal(0);
    });
  });

  describe("Minting", function () {
    it("Should allow factory to mint tokens", async function () {
      const mintAmount = ethers.parseEther("1000");
      
      await expect(
        synthToken.connect(factory).mint(user1.address, mintAmount)
      ).to.emit(synthToken, "Transfer")
      .withArgs(ethers.ZeroAddress, user1.address, mintAmount);
      
      expect(await synthToken.balanceOf(user1.address)).to.equal(mintAmount);
      expect(await synthToken.totalSupply()).to.equal(mintAmount);
    });

    it("Should not allow non-factory to mint", async function () {
      const mintAmount = ethers.parseEther("1000");
      
      await expect(
        synthToken.connect(unauthorized).mint(user1.address, mintAmount)
      ).to.be.revertedWith("SynthToken: Caller is not a minter");
    });

    it("Should emit Mint event", async function () {
      const mintAmount = ethers.parseEther("1000");
      
      await expect(
        synthToken.connect(factory).mint(user1.address, mintAmount)
      ).to.emit(synthToken, "Transfer")
      .withArgs(ethers.ZeroAddress, user1.address, mintAmount);
    });

    it("Should not mint to zero address", async function () {
      const mintAmount = ethers.parseEther("1000");
      
      await expect(
        synthToken.connect(factory).mint(ethers.ZeroAddress, mintAmount)
      ).to.be.revertedWithCustomError(synthToken, "ERC20InvalidReceiver");
    });
  });

  describe("Burning", function () {
    beforeEach(async function () {
      // Mint some tokens first
      const mintAmount = ethers.parseEther("1000");
      await synthToken.connect(factory).mint(user1.address, mintAmount);
      
      // Grant allowance for factory to burn user1's tokens
      await synthToken.connect(user1).approve(factory.address, mintAmount);
    });

    it("Should allow factory to burn tokens", async function () {
      const burnAmount = ethers.parseEther("500");
      
      await expect(
        synthToken.connect(factory).burnFrom(user1.address, burnAmount)
      ).to.emit(synthToken, "Transfer")
      .withArgs(user1.address, ethers.ZeroAddress, burnAmount);
      
      expect(await synthToken.balanceOf(user1.address)).to.equal(ethers.parseEther("500"));
      expect(await synthToken.totalSupply()).to.equal(ethers.parseEther("500"));
    });

    it("Should allow users to burn their own tokens", async function () {
      const burnAmount = ethers.parseEther("300");
      
      await expect(
        synthToken.connect(user1).burn(burnAmount)
      ).to.emit(synthToken, "Transfer")
      .withArgs(user1.address, ethers.ZeroAddress, burnAmount);
      
      expect(await synthToken.balanceOf(user1.address)).to.equal(ethers.parseEther("700"));
    });

    it("Should not allow burning more than balance", async function () {
      const burnAmount = ethers.parseEther("1500"); // More than balance
      
      await expect(
        synthToken.connect(user1).burn(burnAmount)
      ).to.be.revertedWithCustomError(synthToken, "ERC20InsufficientBalance");
    });

    it("Should emit Transfer event on burn", async function () {
      const burnAmount = ethers.parseEther("200");
      
      await expect(
        synthToken.connect(factory).burnFrom(user1.address, burnAmount)
      ).to.emit(synthToken, "Transfer")
      .withArgs(user1.address, ethers.ZeroAddress, burnAmount);
    });

    it("Should not allow non-burner to burn others' tokens", async function () {
      const burnAmount = ethers.parseEther("100");
      
      await expect(
        synthToken.connect(unauthorized).burnFrom(user1.address, burnAmount)
      ).to.be.revertedWith("SynthToken: Caller is not a burner");
    });
  });

  describe("Standard ERC20 Functions", function () {
    beforeEach(async function () {
      // Mint tokens to users
      await synthToken.connect(factory).mint(user1.address, ethers.parseEther("1000"));
      await synthToken.connect(factory).mint(user2.address, ethers.parseEther("500"));
    });

    it("Should transfer tokens between users", async function () {
      const transferAmount = ethers.parseEther("100");
      
      await expect(
        synthToken.connect(user1).transfer(user2.address, transferAmount)
      ).to.emit(synthToken, "Transfer")
      .withArgs(user1.address, user2.address, transferAmount);
      
      expect(await synthToken.balanceOf(user1.address)).to.equal(ethers.parseEther("900"));
      expect(await synthToken.balanceOf(user2.address)).to.equal(ethers.parseEther("600"));
    });

    it("Should approve spending allowance", async function () {
      const allowanceAmount = ethers.parseEther("200");
      
      await expect(
        synthToken.connect(user1).approve(user2.address, allowanceAmount)
      ).to.emit(synthToken, "Approval")
      .withArgs(user1.address, user2.address, allowanceAmount);
      
      expect(await synthToken.allowance(user1.address, user2.address)).to.equal(allowanceAmount);
    });

    it("Should transfer from with allowance", async function () {
      const allowanceAmount = ethers.parseEther("200");
      const transferAmount = ethers.parseEther("150");
      
      // Set allowance
      await synthToken.connect(user1).approve(user2.address, allowanceAmount);
      
      // Transfer from
      await expect(
        synthToken.connect(user2).transferFrom(user1.address, user2.address, transferAmount)
      ).to.emit(synthToken, "Transfer")
      .withArgs(user1.address, user2.address, transferAmount);
      
      expect(await synthToken.balanceOf(user1.address)).to.equal(ethers.parseEther("850"));
      expect(await synthToken.balanceOf(user2.address)).to.equal(ethers.parseEther("650"));
      expect(await synthToken.allowance(user1.address, user2.address)).to.equal(ethers.parseEther("50"));
    });

    it("Should not transfer more than balance", async function () {
      const transferAmount = ethers.parseEther("1500"); // More than balance
      
      await expect(
        synthToken.connect(user1).transfer(user2.address, transferAmount)
      ).to.be.revertedWithCustomError(synthToken, "ERC20InsufficientBalance");
    });

    it("Should not transfer more than allowance", async function () {
      const allowanceAmount = ethers.parseEther("100");
      const transferAmount = ethers.parseEther("150"); // More than allowance
      
      await synthToken.connect(user1).approve(user2.address, allowanceAmount);
      
      await expect(
        synthToken.connect(user2).transferFrom(user1.address, user2.address, transferAmount)
      ).to.be.revertedWithCustomError(synthToken, "ERC20InsufficientAllowance");
    });
  });

  describe("Pausable Functionality", function () {
    it("Should not have pausable functionality", async function () {
      // SynthToken doesn't implement pausable functionality
      expect(synthToken.pause).to.be.undefined;
      expect(synthToken.unpause).to.be.undefined;
      expect(synthToken.paused).to.be.undefined;
    });
  });

  describe("Access Control", function () {
    it("Should have correct default admin role", async function () {
      const defaultAdminRole = await synthToken.DEFAULT_ADMIN_ROLE();
      expect(await synthToken.hasRole(defaultAdminRole, factory.address)).to.be.true;
    });

    it("Should allow admin to grant minter role", async function () {
      const minterRole = await synthToken.MINTER_ROLE();
      
      await synthToken.connect(factory).grantRole(minterRole, user1.address);
      expect(await synthToken.hasRole(minterRole, user1.address)).to.be.true;
    });

    it("Should allow admin to revoke minter role", async function () {
      const minterRole = await synthToken.MINTER_ROLE();
      
      await synthToken.connect(factory).grantRole(minterRole, user1.address);
      await synthToken.connect(factory).revokeRole(minterRole, user1.address);
      expect(await synthToken.hasRole(minterRole, user1.address)).to.be.false;
    });

    it("Should allow admin to grant burner role", async function () {
      const burnerRole = await synthToken.BURNER_ROLE();
      
      await synthToken.connect(factory).grantRole(burnerRole, user1.address);
      expect(await synthToken.hasRole(burnerRole, user1.address)).to.be.true;
    });

    it("Should not allow non-admin to grant roles", async function () {
      const minterRole = await synthToken.MINTER_ROLE();
      
      await expect(
        synthToken.connect(unauthorized).grantRole(minterRole, user1.address)
      ).to.be.revertedWithCustomError(synthToken, "AccessControlUnauthorizedAccount");
    });
  });

  describe("Edge Cases", function () {
    it("Should handle zero amount mints", async function () {
      await expect(
        synthToken.connect(factory).mint(user1.address, 0)
      ).to.not.be.reverted;
      
      expect(await synthToken.balanceOf(user1.address)).to.equal(0);
      expect(await synthToken.totalSupply()).to.equal(0);
    });

    it("Should handle zero amount burns", async function () {
      await synthToken.connect(factory).mint(user1.address, ethers.parseEther("100"));
      
      await expect(
        synthToken.connect(user1).burn(0)
      ).to.not.be.reverted;
      
      expect(await synthToken.balanceOf(user1.address)).to.equal(ethers.parseEther("100"));
    });

    it("Should handle zero amount transfers", async function () {
      await synthToken.connect(factory).mint(user1.address, ethers.parseEther("100"));
      
      await expect(
        synthToken.connect(user1).transfer(user2.address, 0)
      ).to.not.be.reverted;
      
      expect(await synthToken.balanceOf(user1.address)).to.equal(ethers.parseEther("100"));
      expect(await synthToken.balanceOf(user2.address)).to.equal(0);
    });

    it("Should handle maximum uint256 allowance", async function () {
      const maxAllowance = ethers.MaxUint256;
      
      await synthToken.connect(user1).approve(user2.address, maxAllowance);
      expect(await synthToken.allowance(user1.address, user2.address)).to.equal(maxAllowance);
    });
  });

  describe("Integration Scenarios", function () {
    it("Should handle multiple mints and burns", async function () {
      // Multiple mints
      await synthToken.connect(factory).mint(user1.address, ethers.parseEther("500"));
      await synthToken.connect(factory).mint(user1.address, ethers.parseEther("300"));
      await synthToken.connect(factory).mint(user2.address, ethers.parseEther("200"));
      
      expect(await synthToken.totalSupply()).to.equal(ethers.parseEther("1000"));
      expect(await synthToken.balanceOf(user1.address)).to.equal(ethers.parseEther("800"));
      expect(await synthToken.balanceOf(user2.address)).to.equal(ethers.parseEther("200"));
      
      // Set up allowances for burning
      await synthToken.connect(user2).approve(factory.address, ethers.parseEther("50"));
      
      // Multiple burns
      await synthToken.connect(user1).burn(ethers.parseEther("100"));
      await synthToken.connect(factory).burnFrom(user2.address, ethers.parseEther("50"));
      
      expect(await synthToken.totalSupply()).to.equal(ethers.parseEther("850"));
      expect(await synthToken.balanceOf(user1.address)).to.equal(ethers.parseEther("700"));
      expect(await synthToken.balanceOf(user2.address)).to.equal(ethers.parseEther("150"));
    });

    it("Should handle complex transfer scenarios", async function () {
      // Setup
      await synthToken.connect(factory).mint(user1.address, ethers.parseEther("1000"));
      await synthToken.connect(factory).mint(user2.address, ethers.parseEther("500"));
      
      // Complex transfers
      await synthToken.connect(user1).transfer(user2.address, ethers.parseEther("200"));
      await synthToken.connect(user2).approve(user1.address, ethers.parseEther("300"));
      await synthToken.connect(user1).transferFrom(user2.address, user1.address, ethers.parseEther("100"));
      
      expect(await synthToken.balanceOf(user1.address)).to.equal(ethers.parseEther("900"));
      expect(await synthToken.balanceOf(user2.address)).to.equal(ethers.parseEther("600"));
      expect(await synthToken.allowance(user2.address, user1.address)).to.equal(ethers.parseEther("200"));
    });
  });
}); 