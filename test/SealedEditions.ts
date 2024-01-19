import {
    time,
    loadFixture,
} from "@nomicfoundation/hardhat-toolbox/network-helpers";
import { expect } from "chai";
import { ethers, network } from "hardhat";
import { signRaw } from "./utils";

const eth = (v:string|number)=>ethers.parseEther(typeof v === "number"?v.toString():v)

describe("SealedEditions", function () {
    async function deployExchangeFixture() {
        const [sequencer, seller, buyer, treasury] = await ethers.getSigners();

        const editions = await (await ethers.getContractFactory("SealedEditions")).deploy(sequencer.address);
        const artist = await ethers.getImpersonatedSigner("0x334f95d8ffdb85a0297c6f7216e793d08ab45b48");
        const manifoldContract = new ethers.Contract("0xE2000AddF46e0331C2806Adf24B052354a7EC218", [
            "function registerExtension(address, string) external",
            "function transferOwnership(address) external",
            "function balanceOf(address, uint) external view returns (uint)",
            "function uri(uint) external view returns (string memory)"
        ], seller)
        await (manifoldContract.connect(artist) as any).transferOwnership(seller.address)
        await manifoldContract.registerExtension(await editions.getAddress(), "")

        const chainIdHex = await network.provider.send('eth_chainId');

        async function sign(signer: typeof sequencer, types: any, value: any, contract?:string) {
            return signRaw(signer, types, value, contract ?? await editions.getAddress(), chainIdHex)
        }

        return { editions, artist, manifoldContract, sequencer, seller, buyer, treasury, sign };
    }
    it("basic flow", async function () {
        const {  sequencer, seller, buyer, treasury, sign, editions, artist, manifoldContract } = await loadFixture(deployExchangeFixture);

        const nftContract= await manifoldContract.getAddress(),
        uri= "ipfs://w8esse",
        cost= eth("0.1"),
        endDate= (await time.latest()) + 10 * 60,
        maxToMint= 100,
        deadline= (await time.latest()) + 10 * 60,
        counter= 1,
        nonce= 1;
        const offer = await sign(seller, {
            SellOffer:[
                { name: "nftContract", type: "address" },
                { name: "uri", type: "string" },
                { name: "cost", type: "uint256" },
                { name: "endDate", type: "uint256" },
                { name: "maxToMint", type: "uint256" },
                { name: "deadline", type: "uint256" },
                { name: "counter", type: "uint256" },
                { name: "nonce", type: "uint256" },
            ]
        }, {
            nftContract,
            uri,
            cost,
            endDate,
            maxToMint,
            deadline,
            counter,
            nonce,
        }, await editions.getAddress())
        const attestation = await sign(sequencer, {
            MintOfferAttestation: [
                { name: "deadline", type: "uint256" },
                { name: "offerHash", type: "bytes32" },
            ]
        }, {
            deadline: (await time.latest()) + 10 * 60,
            offerHash: ethers.keccak256(new ethers.AbiCoder().encode(
                ["address", "address", "address", "string", "uint256", "uint256", "uint256", "uint256", "uint256", "uint256"], 
                [buyer.address, seller.address, nftContract, uri, cost, endDate,
                    maxToMint,
                    deadline,
                    counter,
                    nonce,])),
        }, await editions.getAddress())
        const nftId = 4n
        await expect(editions.connect(buyer).mint(1, nftContract, nftId, cost, endDate, maxToMint, seller.address, {
            value: eth(0.1)
        })).to.be.revertedWith(">maxToMint")
        expect(await manifoldContract.balanceOf(buyer.address, nftId)).to.eq(0)
        const mintTx = await editions.connect(buyer).mintNew(offer, attestation, 1, {
            value: eth(0.1)
        })
        expect(((await mintTx.wait())!.logs!.find((l:any)=>l.fragment?.name==="Mint")! as any).args[1]).to.eq(nftId)
        expect(await manifoldContract.balanceOf(buyer.address, nftId)).to.eq(1)
        await editions.connect(buyer).mint(1, nftContract, nftId, cost, endDate, maxToMint, seller.address, {
            value: eth(0.1)
        })
        expect(await manifoldContract.balanceOf(buyer.address, nftId)).to.eq(2)
        await editions.connect(buyer).mintNew(offer, attestation, 3, {
            value: eth(0.3)
        }) // goes to mint()
        expect(await manifoldContract.balanceOf(buyer.address, nftId)).to.eq(5)
        await expect(editions.connect(buyer).mint(95, nftContract, nftId, cost, endDate, maxToMint, seller.address, {value: eth(9.4)}))
            .to.be.revertedWith("msg.value")
        await expect(editions.connect(buyer).mint(96, nftContract, nftId, cost, endDate, maxToMint, seller.address, {value: eth(9.5)}))
            .to.be.revertedWith(">maxToMint")
        await editions.connect(seller).stopMint(nftContract, nftId, cost, endDate, maxToMint)
        await expect(editions.connect(buyer).mint(1, nftContract, nftId, cost, endDate, maxToMint, seller.address, {value: eth(0.1)}))
            .to.be.revertedWithPanic("0x11") // overflow
        expect(await manifoldContract.uri(nftId)).to.eq(uri)
    })
})