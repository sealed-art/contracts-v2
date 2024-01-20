import {
    time,
    loadFixture,
} from "@nomicfoundation/hardhat-toolbox/network-helpers";
import { expect } from "chai";
import { ethers, network } from "hardhat";
import { signRaw } from "./utils";
import { MerkleTree } from 'merkletreejs'
import keccak256 from "keccak256"

const eth = (v: string | number) => ethers.parseEther(typeof v === "number" ? v.toString() : v)

function paddedBuffer({addr, startDate, cost, maxMint}:{addr:string, startDate:number, cost:bigint, maxMint:number}){
    const buf = Buffer.from(addr.substr(2).padStart(32*2, "0")
        +startDate.toString(16).padStart(32*2, "0")
        +cost.toString(16).padStart(32*2, "0")
        +maxMint.toString(16).padStart(32*2, "0"), "hex")
    return keccak256(buf)
}

describe("SealedEditions", function () {
    async function deployExchangeFixture() {
        const [owner, sequencer, seller, buyer, delegate] = await ethers.getSigners();

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

        async function sign(signer: typeof sequencer, types: any, value: any, contract?: string) {
            return signRaw(signer, types, value, contract ?? await editions.getAddress(), chainIdHex)
        }

        const nftContract = await manifoldContract.getAddress(),
            uri = "ipfs://QmbWjQEGi4qAAkZWVEiDvdkk7fu91kRJLEqb9mD5w8esse",
            cost = eth("0.1"),
            startDate = 0,
            endDate = (await time.latest()) + 10 * 60,
            maxToMint = 100,
            merkleRoot = "0x0000000000000000000000000000000000000000000000000000000000000000"

        return { editions, artist, manifoldContract, sequencer, seller, buyer, owner, delegate, sign, defaultParams:{
            nftContract, uri, cost, startDate, endDate, maxToMint, merkleRoot
        } };
    }
    async function getSigs(seller: any, buyer: any, sequencer: any, sign: any, editions: any, nftContract: string,
        uri: string,
        cost: bigint,
        startDate: number,
        endDate: number,
        maxToMint: number,
        merkleRoot: string) {
        const deadline = (await time.latest()) + 10 * 60,
            counter = 1,
            nonce = 1;
        const offer = await sign(seller, {
            SellOffer: [
                { name: "nftContract", type: "address" },
                { name: "uri", type: "string" },
                { name: "cost", type: "uint256" },
                { name: "startDate", type: "uint256" },
                { name: "endDate", type: "uint256" },
                { name: "maxToMint", type: "uint256" },
                { name: "merkleRoot", type: "bytes32" },
                { name: "deadline", type: "uint256" },
                { name: "counter", type: "uint256" },
                { name: "nonce", type: "uint256" },
            ]
        }, {
            nftContract,
            uri,
            cost,
            startDate,
            endDate,
            maxToMint,
            merkleRoot,
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
                ["address", "address", "address", "string", "uint256", "uint256", "uint256", "uint256", "bytes32", "uint256", "uint256", "uint256"],
                [buyer.address, seller.address, nftContract, uri, cost, startDate, endDate,
                    maxToMint, merkleRoot,
                    deadline,
                    counter,
                    nonce,])),
        }, await editions.getAddress())
        return { offer, attestation }
    }
    it("basic flow", async function () {
        const { sequencer, seller, buyer, owner, sign, editions, manifoldContract, defaultParams:{ nftContract, uri, cost, startDate, endDate, maxToMint, merkleRoot } } = await loadFixture(deployExchangeFixture);

        const { offer, attestation } = await getSigs(seller, buyer, sequencer, sign, editions, nftContract, uri, cost, startDate, endDate, maxToMint, merkleRoot)
        const nftId = 4n
        await expect(editions.connect(buyer).mint(1, nftContract, nftId, cost, startDate, endDate, maxToMint, seller.address, merkleRoot, {
            value: eth(0.1)
        })).to.be.revertedWith(">maxToMint")
        expect(await manifoldContract.balanceOf(buyer.address, nftId)).to.eq(0)
        const mintTx = await editions.connect(buyer).mintNew(offer, attestation, 1, {
            value: eth(0.1)
        })
        expect(((await mintTx.wait())!.logs!.find((l: any) => l.fragment?.name === "Mint")! as any).args[1]).to.eq(nftId)
        expect(await manifoldContract.balanceOf(buyer.address, nftId)).to.eq(1)
        await editions.connect(buyer).mint(1, nftContract, nftId, cost, startDate, endDate, maxToMint, seller.address, merkleRoot, {
            value: eth(0.1)
        })
        expect(await manifoldContract.balanceOf(buyer.address, nftId)).to.eq(2)
        await editions.connect(buyer).mintNew(offer, attestation, 3, {
            value: eth(0.3)
        }) // goes to mint()
        expect(await manifoldContract.balanceOf(buyer.address, nftId)).to.eq(5)
        await expect(editions.connect(buyer).mint(95, nftContract, nftId, cost, startDate, endDate, maxToMint, seller.address, merkleRoot, { value: eth(9.4) }))
            .to.be.revertedWith("msg.value")
        await expect(editions.connect(buyer).mint(96, nftContract, nftId, cost, startDate, endDate, maxToMint, seller.address, merkleRoot, { value: eth(9.5) }))
            .to.be.revertedWith(">maxToMint")
        await editions.connect(seller).stopMint(nftContract, nftId, cost, startDate, endDate, maxToMint, merkleRoot)
        await expect(editions.connect(buyer).mint(1, nftContract, nftId, cost, startDate, endDate, maxToMint, seller.address, merkleRoot, { value: eth(0.1) }))
            .to.be.revertedWithPanic("0x11") // overflow
        expect(await manifoldContract.uri(nftId)).to.eq(uri)

        const treasuryAddress = "0x1f9090aae28b8a3dceadf281b0f12828e676c111" // random address
        expect(await sequencer.provider.getBalance(treasuryAddress)).to.eq(0)
        await editions.connect(owner).withdrawFees(treasuryAddress)
        expect(await sequencer.provider.getBalance(treasuryAddress)).to.eq(eth(5*0.1*0.02))
        expect(await sequencer.provider.getBalance(await editions.getAddress())).to.eq(0)
    })

    it("editMint", async function () {
        const { sequencer, seller, buyer, sign, editions, defaultParams:{ nftContract, uri, cost, startDate, endDate, maxToMint, merkleRoot } } = await loadFixture(deployExchangeFixture);

        const { offer, attestation } = await getSigs(seller, buyer, sequencer, sign, editions, nftContract, uri, cost, startDate, endDate, maxToMint, merkleRoot)
        const mintTx = await editions.connect(buyer).mintNew(offer, attestation, 1, {
            value: eth(0.1)
        })
        const nftId = ((await mintTx.wait())!.logs!.find((l: any) => l.fragment?.name === "Mint")! as any).args[1]
        await expect(editions.editMint(nftContract, nftId, cost, startDate, endDate, maxToMint, merkleRoot, eth(1), 1, endDate+1, 10, merkleRoot))
            .to.be.revertedWith("!auth")
        await editions.connect(seller).editMint(nftContract, nftId, cost, startDate, endDate, maxToMint, merkleRoot, eth(1), 1, endDate+1, 10, merkleRoot)
        await expect(editions.connect(buyer).mintNew(offer, attestation, 1, { value: eth(0.1) })).to.be.revertedWithPanic("0x11")
        await expect(editions.connect(buyer).mint(1, nftContract, nftId, cost, startDate, endDate, maxToMint, 
            seller.address, merkleRoot, { value: eth(0.1) })).to.be.revertedWithPanic("0x11")
        const sigs2 = await getSigs(seller, buyer, sequencer, sign, editions, nftContract, uri, eth(1), 1, endDate+1, 10, merkleRoot)
        await editions.connect(buyer).mintNew(sigs2.offer, sigs2.attestation, 1, { value: eth(1) })
    })

    it("cancelOffer", async function () {
        const { sequencer, seller, buyer, sign, editions, defaultParams:{ nftContract, uri, cost, startDate, endDate, maxToMint, merkleRoot } } = await loadFixture(deployExchangeFixture);

        const { offer, attestation } = await getSigs(seller, buyer, sequencer, sign, editions, nftContract, uri, cost, startDate, endDate, maxToMint, merkleRoot)
        await editions.connect(seller).cancelOffer(1)
        await expect(editions.connect(buyer).mintNew(offer, attestation, 1, { value: eth(0.1) })).to.be.revertedWith(">maxToMint")
    })

    it("createMint", async function () {
        const { sequencer, seller, buyer, sign, editions, defaultParams:{ nftContract, uri, cost, startDate, endDate, maxToMint, merkleRoot } } = await loadFixture(deployExchangeFixture);

        const { offer, attestation } = await getSigs(seller, buyer, sequencer, sign, editions, nftContract, uri, cost, startDate, endDate, maxToMint, merkleRoot)
        const mintTx = await editions.connect(buyer).mintNew(offer, attestation, 1, { value: eth(0.1) });
        const nftId = ((await mintTx.wait())!.logs!.find((l: any) => l.fragment?.name === "Mint")! as any).args[1]
        await editions.connect(seller).stopMint(nftContract, nftId, cost, startDate, endDate, maxToMint, merkleRoot)
        await expect(editions.connect(buyer).mint(1, nftContract, nftId, cost, startDate, endDate, maxToMint, seller.address, merkleRoot, { value: eth(0.1) }))
            .to.be.revertedWithPanic("0x11") // overflow
        await editions.connect(seller).createMint(nftContract, nftId, cost, startDate, endDate, maxToMint, merkleRoot, 1)
        await editions.connect(buyer).mint(1, nftContract, nftId, cost, startDate, endDate, maxToMint, seller.address, merkleRoot, { value: eth(0.1) })
    })

    it("merkle mint", async function () {
        const { sequencer, seller, buyer, sign, editions, delegate, defaultParams:{ nftContract, uri, startDate, endDate, maxToMint } } = await loadFixture(deployExchangeFixture);

        const wl = [
            {
                addr: buyer.address,
                startDate:0,
                cost:eth(0.5),
                maxMint:5
            },
            {
                addr: seller.address,
                startDate:1,
                cost:eth(0.5),
                maxMint:5
            },
            {
                addr: sequencer.address,
                startDate:2,
                cost:eth(0.5),
                maxMint:5
            }
        ]
        const tree = new MerkleTree(wl.map(x => paddedBuffer(x)), keccak256, { sort: true })
        const leaf = paddedBuffer(wl[0])
        const proof = tree.getHexProof(leaf)
        const merkleRoot = tree.getHexRoot()

        const cost = eth("2")

        const { offer, attestation } = await getSigs(seller, buyer, sequencer, sign, editions, nftContract, uri, cost, startDate, endDate, maxToMint, merkleRoot)
        await editions.connect(buyer).mintNewWithMerkle(offer, attestation, 1, proof, buyer.address, 0, eth(0.5), 5, { value: eth(0.5) })
        await editions.connect(buyer).mintNewWithMerkle(offer, attestation, 2, proof, buyer.address, 0, eth(0.5), 5, { value: eth(1) })
        await expect(editions.connect(delegate).mintNewWithMerkle(offer, attestation, 1, proof, buyer.address, 0, eth(0.5), 5, { value: eth(0.5) })).to.be.revertedWith("Invalid delegate")
        await expect(editions.connect(buyer).mintNewWithMerkle(offer, attestation, 3, proof, buyer.address, 0, eth(0.5), 5, { value: eth(0.5) })).to.be.revertedWith(">maxMint")
        await expect(editions.connect(buyer).mintNewWithMerkle(offer, attestation, 3, proof, buyer.address, 10, eth(0.5), 5, { value: eth(0.5) })).to.be.revertedWith("bad merkle proof")
        await editions.connect(buyer).mintWithMerkle(1, nftContract, 4n, cost, startDate, endDate, maxToMint, seller.address, merkleRoot,
            proof, buyer.address, 0, eth(0.5), 5, { value: eth(0.5) })
        
        // test with delegation
        const dr = new ethers.Contract("0x00000000000076A84feF008CDAbe6409d2FE638B", [
            "function delegateForContract(address delegate, address contract_, bool value) external",
        ], buyer)
        await dr.delegateForContract(delegate, await editions.getAddress(), true)
        await editions.connect(delegate).mintNewWithMerkle(offer, attestation, 1, proof, buyer.address, 0, eth(0.5), 5, { value: eth(0.5) })
    })
})