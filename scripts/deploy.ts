import { ethers } from "hardhat";

async function main() {
  const contract = await ethers.deployContract("SealedArtMarket", 
    ["0xcA2A693A03b49bBc3A25AE7cCc3c36335235Eeac", "0xcA2A693A03b49bBc3A25AE7cCc3c36335235Eeac", "0xcA2A693A03b49bBc3A25AE7cCc3c36335235Eeac"]);

  await contract.waitForDeployment();

  console.log(
    `deployed to ${contract.target}`
  );

  console.log(`factory at ${await contract.sealedFundingFactory()}`)
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
