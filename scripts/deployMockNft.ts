import { ethers } from "hardhat";

async function main() {
  const contract = await ethers.deployContract("MockNFT")

  await contract.waitForDeployment();

  console.log(
    `deployed to ${contract.target}`
  );
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
