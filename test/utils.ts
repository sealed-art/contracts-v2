import { ethers } from "hardhat";

export async function signRaw(signer: any, types: any, value: any, contract:string, chainIdHex:string) {
    const domain = {
        name: "SealedArtMarket",
        version: "1",
        chainId: chainIdHex,
        verifyingContract: contract
    };

    const signature = await signer.signTypedData(domain, types, value);
    const { r, s, v } = ethers.Signature.from(signature)
    return { ...value, r, s, v }
}