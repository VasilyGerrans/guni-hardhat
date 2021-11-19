const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");
const erc20abi = require("../abis/ERC20");
const vatAbi = require("../abis/Vat");
const Web3 = require("web3");
const { BigNumber } = require("@ethersproject/bignumber");

describe("GuniLev Contracts", function () {
  this.timeout(0); // prevent 20000ms timeout

  let deployer, whale, GuniLev, guniLev, GuniLevWind, guniLevWind, GuniLevUnwind, guniLevUnwind, DaiContract, OtherTokenContract, VatContract;
  const vat = "0x35D1b3F3D7966A1DFe207aa4514C12a259A0492B";
  const dai = "0x6B175474E89094C44Da98b954EedeAC495271d0F";
  const other = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";
  const join = "0xbFD445A97e7459b0eBb34cfbd3245750Dba4d7a4";
  const daiJoin = "0x9759A6Ac90977b93B58547b4A71c78317f391A28";
  const spotter = "0x65C79fcB50Ca1594B025960e539eD7A9a6D434A3";
  const lender = "0x1EB4CF3A948E7D72A198fe073cCb8C7a948cD853";
  const curve = "0xbEbc44782C7dB0a1A60Cb6fe97d0b483032FF1C7"; // 3-pool
  const router = "0x14E6D67F824C3a7b4329d3228807f8654294e4bd";
  const resolver = "0x0317650Af6f184344D7368AC8bB0bEbA5EDB214a";

  const whaleAddress = "0x4967EC98748EFB98490663A65b16698069A1Eb35";

  const initialAmount = Web3.utils.toWei("50000", "ether");

  beforeEach(async () => {
    [deployer, _] = await ethers.getSigners();
    await hre.network.provider.request({
      method: "hardhat_impersonateAccount",
      params: [whaleAddress],
    });
    whale = await ethers.getSigner(whaleAddress);

    VatContract = new ethers.Contract(vat, vatAbi, ethers.provider);
    OtherTokenContract = new ethers.Contract(other, erc20abi, ethers.provider); // USDC
    DaiContract = new ethers.Contract(dai, erc20abi, ethers.provider);

    GuniLev = await ethers.getContractFactory("GuniLev");
    guniLev = await upgrades.deployProxy(GuniLev, [
      join,
      daiJoin,
      spotter,
      lender,
      router,
      resolver,
      curve,
      0,
      1
    ], {initializer: "initialize"});
    await guniLev.deployed();

    GuniLevWind = await ethers.getContractFactory("GuniLevWind");
    guniLevWind = await GuniLevWind.deploy();
    await guniLevWind.initialize(guniLev.address);

    GuniLevUnwind = await ethers.getContractFactory("GuniLevUnwind");
    guniLevUnwind = await GuniLevUnwind.deploy();
    await guniLevUnwind.initialize(guniLev.address);

    guniLev.setWinders(guniLevWind.address, guniLevUnwind.address);

    await DaiContract.connect(whale).transfer(deployer.address, initialAmount);
    await DaiContract.connect(deployer).approve(guniLev.address, initialAmount);
  });

  describe("deployment", async () => {
    it("gives me 50,000 dai", async () => {
      let balance = await DaiContract.balanceOf(deployer.address);

      expect(balance.toString()).to.be.equal(initialAmount);
    });

    it("has an existing poolWinder with the values we inputted", async () => {
      var poolWinder = await guniLev.getPoolWinder("0x47554e49563344414955534443312d4100000000000000000000000000000000"); // the DAI-USDC ilk

      expect(poolWinder[0]).to.be.equal(join);
      expect(poolWinder[1]).to.be.equal(other);
      expect(poolWinder[2]).to.be.equal(curve);
    });
  });

  describe("estimation methods", async () => {
    it("gets total cost estimate", async () => {
      const cost = await guniLev.getEstimatedCostToWindUnwind(deployer.address, initialAmount);
      const relCostBPS = cost.mul(1000).div(initialAmount);

      expect(relCostBPS.lt(BigNumber.from(800))).to.be.true; // expect up to 8% in losses due to slippage
    });

    it("gets wind estimates", async () => {
      const res = await guniLev.getWindEstimates(deployer.address, initialAmount);

      const benchmark = BigNumber.from(10).pow(BigNumber.from(18)).mul(BigNumber.from(2122));
      const deviation = BigNumber.from(10).pow(BigNumber.from(18)).mul(BigNumber.from(500));
      const difference = res.estimatedDaiRemaining.sub(benchmark).abs();

      expect(difference.lt(deviation)).to.be.true; // expect no more than 500 Dai deviation from our estimate
    });

    /*  
    
    Always fails with reason string 'Vat/ceiling-exceeded'
    
    it("gets unwind estimates", async () => {
      await guniLev.wind(initialAmount, 0);

      const daiAfterUnwind = await guniLev.getUnwindEstimates(deployer.address);

      console.log(daiAfterUnwind.toString());
    });
    
    */
  });

  describe("trades", async () => {
    /*

    Will always fail with reason string 'Vat/ceiling-exceeded'

    (unless I edit the block first)

    This issue was present in the original guni-lev project

    */
  });
});
