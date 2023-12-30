import { ethers } from "ethers";

async function main() {
    console.log(await new ethers.Contract("0x2cBe14b7F60Fbe6A323cBA7Db56f2D916C137F3C", ["function sealedFundingFactory() view returns (address)"], new ethers.CloudflareProvider()).sealedFundingFactory())
  //console.log(await ((await ethers.getContractFactory("SealedArtMarket")).attach("0x2cBe14b7F60Fbe6A323cBA7Db56f2D916C137F3C") as any).sealedFundingFactory())
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});