import {
    time,
    loadFixture,
} from "@nomicfoundation/hardhat-toolbox/network-helpers";
import { expect } from "chai";
import { ethers, network } from "hardhat";
import { signRaw } from "./utils";

const eth = (v:string|number)=>ethers.parseEther(typeof v === "number"?v.toString():v)
const DAY = 24*3600
const SAMPLE_AUCTION_TYPE = "0x0000000000000000000000000000000000000000000000000000000000000001"

describe("SealedArtMarket", function () {
    async function deployExchangeFixture() {
        const [sequencer, seller, buyer, treasury] = await ethers.getSigners();

        const SealedArtExchange = await ethers.getContractFactory("SealedPool");
        const sa = await SealedArtExchange.deploy(sequencer.address);
        const fundingFactory = (await ethers.getContractFactory("SealedFundingFactory")).attach(await sa.sealedFundingFactory()) as any

        const mockNFT = await (await ethers.getContractFactory("MockNFT")).deploy();
        const mockToken = await (await ethers.getContractFactory("MockToken")).deploy();

        const chainIdHex = await network.provider.send('eth_chainId');

        async function sign(signer: typeof sequencer, types: any, value: any, contract?:string) {
            return signRaw(signer, types, value, contract ?? await sa.getAddress(), chainIdHex)
        }

        return { sa, sequencer, seller, buyer, treasury, sign, mockNFT, mockToken, fundingFactory };
    }

    it("should not be possible to send ETH to SealedFunding after deployment", async function () {
        const { sa, buyer, mockNFT, mockToken, fundingFactory } = await loadFixture(deployExchangeFixture);
        expect(await sa.balanceOf(buyer.address)).to.equal(0);
        const salt = "0x0000000000000000000000000000000000000000000000000000000000000001"
        const hiddenFunding = await fundingFactory.computeSealedFundingAddress(salt, buyer.address)
        await buyer.sendTransaction({
            to: hiddenFunding.predictedAddress,
            value: ethers.parseEther("1.0"), // Sends exactly 1.0 ether
        });
        expect(buyer.sendTransaction({
            to: hiddenFunding.predictedAddress,
            value: ethers.parseEther("0.5"),
        })).not.to.be.reverted
        await fundingFactory.deploySealedFunding(salt, buyer.address)
        expect(await sa.balanceOf(buyer.address)).to.equal(ethers.parseEther("1.5"));
        expect(buyer.sendTransaction({
            to: hiddenFunding.predictedAddress,
            value: ethers.parseEther("1.0")
        })).to.be.reverted
    });

    it("basic auction workflow", async function () {
        const { sa, sequencer, seller, buyer, sign, mockNFT, fundingFactory } = await loadFixture(deployExchangeFixture);
        await mockNFT.mintId(seller.address, 34)
        const auctions = await (await ethers.getContractFactory("Auctions")).deploy(sequencer.address, sequencer.address, sequencer.address, await sa.getAddress());
        mockNFT.connect(seller).setApprovalForAll(await auctions.getAddress(), true)
        auctions.connect(seller).createAuction(await mockNFT.getAddress(), 123, SAMPLE_AUCTION_TYPE, 34, eth("1"))
        expect(await sa.balanceOf(buyer.address)).to.equal(eth(0));
        await sa.connect(buyer).deposit(buyer.address, {value: eth("0.5")})
        expect(await sa.balanceOf(buyer.address)).to.equal(eth(0.5));
        const salt = "0x0000000000000000000000000000000000000000000000000000000000000021"
        const salt2 = "0x0000000000000000000000000000000000000000000000000000000000000024"
        const hiddenFunding = await fundingFactory.computeSealedFundingAddress(salt, buyer.address)
        await buyer.sendTransaction({
            to: hiddenFunding.predictedAddress,
            value: eth("1.0"),
        });

        const auctionId = await auctions.calculateAuctionHash(seller.address, await mockNFT.getAddress(), SAMPLE_AUCTION_TYPE, 34, eth("1"))
        // Test that one salt being already revealed doesnt cause tx to revert
        const hiddenFunding2 = await fundingFactory.computeSealedFundingAddress(salt2, buyer.address)
        await buyer.sendTransaction({
            to: hiddenFunding2.predictedAddress,
            value: eth("0.1"),
        });
        await fundingFactory.deploySealedFunding(salt, buyer.address)
        await fundingFactory.deploySealedFunding(salt2, buyer.address)
        await sa.settleWithSealedBids([salt2], await sign(buyer, {
            Action: [
                { name: "maxAmount", type: "uint256" },
                { name: "operator", type: "address" },
                { name: "sigHash", type: "bytes4" },
                { name: "data", type: "bytes" },
            ],
        }, {
            maxAmount: eth("3"),
            operator: await auctions.getAddress(),
            sigHash: auctions.interface.getFunction("settleAuction").selector,
            data: auctionId
        }), await sign(sequencer, {
            ActionAttestation: [
                { name: "deadline", type: "uint256" },
                { name: "amount", type: "uint256" },
                { name: "nonce", type: "uint256" },
                { name: "account", type: "address" },
                { name: "callHash", type: "bytes32" },
                { name: "attestationData", type: "bytes" },
            ],
        }, {
            deadline: (await time.latest()) + 10 * 60,
            amount: eth("1"),
            nonce: 1,
            account: buyer.address,
            callHash: ethers.keccak256(new ethers.AbiCoder().encode(["address", "bytes"], [await auctions.getAddress(), auctionId])),
            attestationData: new ethers.AbiCoder().encode(["address", "address", "bytes32", "uint256", "uint256"], 
                [seller.address, await mockNFT.getAddress(), SAMPLE_AUCTION_TYPE, 34, eth("1")])
        }))
        expect(await mockNFT.ownerOf(34)).to.eq(buyer.address)
    })


    it("mint auction workflow", async function () {
        const { sa, sequencer, seller, buyer, sign, mockNFT, fundingFactory } = await loadFixture(deployExchangeFixture);
        const auctions = await (await ethers.getContractFactory("MintAuctions")).deploy(sequencer.address, sequencer.address, sequencer.address, await sa.getAddress());
        const artist = await ethers.getImpersonatedSigner("0x8c3bb3dfa925eeb309244724e162976ffbe07a98");
        await buyer.sendTransaction({
            to: artist.address,
            value: eth("4"),
        });
        const manifoldContract = new ethers.Contract("0x29a30ee15ce1c299294a257dd4cd8bd4d5d9b5de", [
            "function registerExtension(address, string) external",
            "function transferOwnership(address) external",
        ], seller)
        await (manifoldContract.connect(artist) as any).transferOwnership(seller.address)
        await manifoldContract.registerExtension(await auctions.getAddress(), "uri://")
        const uri = "URI"
        const mintHash = ethers.keccak256(new ethers.AbiCoder().encode(["address", "string"], [await manifoldContract.getAddress(), uri]))
        const sellerSig = await sign(seller, {
            SellOffer: [
                { name: "mintHash", type: "bytes32" },
                { name: "amount", type: "uint256" },
                { name: "deadline", type: "uint256" },
                { name: "counter", type: "uint256" },
                { name: "nonce", type: "uint256" },
            ],
        }, {
            mintHash,
            amount: eth("2"),
            deadline: (await time.latest()) + 10 * 60,
            counter: 1,
            nonce: 1
        }, await auctions.getAddress())
        const buyerOffer = new ethers.AbiCoder().encode(["bytes32", "uint256", "uint256"], [mintHash, 1, 1])
        const sellerOffer = new ethers.AbiCoder().encode(["uint8", "bytes32", "bytes32", "bytes32", "uint256", "uint256", "uint256", "uint256"], 
            [sellerSig.v, sellerSig.r, sellerSig.s, sellerSig.mintHash, sellerSig.amount, sellerSig.deadline, sellerSig.counter, sellerSig.nonce])
        const actionData = buyerOffer + sellerOffer.slice(2)
        const encodedCall = await auctions.settle.populateTransaction(buyer.address, buyer.address, 1, 5, 6, 7, {
            mintHash,
            counter: 1,
            nonce: 1
        }, sellerSig,
            8, {
            seller: seller.address,
            nftContract: await manifoldContract.getAddress(),
            uri
        })
        await sa.settle(await sign(buyer, {
            Action: [
                { name: "maxAmount", type: "uint256" },
                { name: "operator", type: "address" },
                { name: "sigHash", type: "bytes4" },
                { name: "data", type: "bytes" },
            ],
        }, {
            maxAmount: eth("3"),
            operator: await auctions.getAddress(),
            sigHash: auctions.interface.getFunction("settle").selector,
            data: actionData
        }), await sign(sequencer, {
            ActionAttestation: [
                { name: "deadline", type: "uint256" },
                { name: "amount", type: "uint256" },
                { name: "nonce", type: "uint256" },
                { name: "account", type: "address" },
                { name: "callHash", type: "bytes32" },
                { name: "attestationData", type: "bytes" },
            ],
        }, {
            deadline: (await time.latest()) + 10 * 60,
            amount: eth("3"),
            nonce: 1,
            account: buyer.address,
            callHash: ethers.keccak256(new ethers.AbiCoder().encode(["address", "bytes"], [await auctions.getAddress(), actionData])),
            attestationData: "0x"+encodedCall.data.slice(1162)//"0x00000000000000000000000000000000000000000000000000000000000002600000000000000000000000008c3bb3dfa925eeb309244724e162976ffbe07a9800000000000000000000000029a30ee15ce1c299294a257dd4cd8bd4d5d9b5de000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000035552490000000000000000000000000000000000000000000000000000000000"//finalAttestationData
        }), {
            value: eth("3")
        })
    })

    it("backwards compatible settleOld auction", async function () {
        const { sa, sequencer, seller, buyer, sign, mockNFT, fundingFactory } = await loadFixture(deployExchangeFixture);
        await mockNFT.mintId(seller.address, 34)
        const oldSealed = new ethers.Contract("0x2cbe14b7f60fbe6a323cba7db56f2d916c137f3c", [
            "function createAuction(address nftContract,uint256 auctionDuration,bytes32 auctionType,uint256 nftId,uint256 reserve) external",
            "function calculateAuctionHash(address owner,address nftContract,bytes32 auctionType,uint256 nftId,uint256 reserve) public pure returns (bytes32)",
            "function changeSequencer(address, address) external"
        ], seller)
        const oldOwner = await ethers.getImpersonatedSigner("0xE4FA009d01B2cd9c9B0F81fd3e45095EF0F1005C");
        (oldSealed.connect(oldOwner) as any).changeSequencer(sequencer.address, sequencer.address)
        mockNFT.connect(seller).setApprovalForAll(await oldSealed.getAddress(), true)
        oldSealed.createAuction(await mockNFT.getAddress(), 123, SAMPLE_AUCTION_TYPE, 34, eth("1"))
        const auctionId = await oldSealed.calculateAuctionHash(seller.address, await mockNFT.getAddress(), SAMPLE_AUCTION_TYPE, 34, eth("1"))
        const bidSig = await sign(buyer, {
            Bid: [
                { name: "auctionId", type: "bytes32" },
                { name: "maxAmount", type: "uint256" },
            ],
        }, {
            auctionId: auctionId,
            maxAmount: eth("2")
        }, await oldSealed.getAddress())
        const seqSig = await sign(sequencer, {
            BidWinner: [
                { name: "auctionId", type: "bytes32" },
                { name: "amount", type: "uint256" },
                { name: "winner", type: "address" },
            ],
        }, {
            auctionId: auctionId,
            amount: eth("1"),
            winner: buyer.address,
        }, await oldSealed.getAddress())
        await sa.connect(buyer).deposit(buyer.address, {value: eth("2")})
        await sa.settleOld([], [], seller.address, await mockNFT.getAddress(), SAMPLE_AUCTION_TYPE, 34, eth("1"), bidSig, seqSig)
        expect(await mockNFT.ownerOf(34)).to.eq(buyer.address)
    })

    it("signed withdrawal", async function () {
        const { sa, sequencer, seller, buyer, sign, mockNFT, fundingFactory } = await loadFixture(deployExchangeFixture);
        await sa.connect(buyer).deposit(buyer.address, {value: eth("2")})
        await sa.connect(buyer).deposit(seller.address, {value: eth("3")})
        const seqVal = {
            deadline: (await time.latest())+10*60,
            amount: eth("1"),
            nonce:69,
            account: buyer.address,
        }
        const seqSig = await sign(sequencer, {
            VerifyWithdrawal: [
                { name: "deadline", type: "uint256" },
                { name: "amount", type: "uint256" },
                { name: "nonce", type: "uint256" },
                { name: "account", type: "address" },
            ],
        }, seqVal)
        await expect(sa.connect(seller).withdraw({...seqVal, ...seqSig})).to.be.revertedWith("not sender")
        expect(await sa.balanceOf(buyer.address)).to.eq(eth(2))
        await sa.connect(buyer).withdraw({...seqVal, ...seqSig})
        expect(await sa.balanceOf(buyer.address)).to.eq(eth(1))
        await expect(sa.connect(buyer).withdraw({...seqVal, ...seqSig})).to.be.revertedWith("replayed")
    })

    it("delayed ETH withdrawal", async function () {
        const { sa, sequencer, seller, buyer, sign, mockNFT, fundingFactory } = await loadFixture(deployExchangeFixture);
        await sa.connect(buyer).deposit(buyer.address, {value: eth("2")})
        const startTx = await sa.connect(buyer).startWithdrawal(eth(2), 1)
        const startTime = (((await startTx.wait())!.logs)[0] as any).args[1]
        await expect(sa.executePendingWithdrawal(startTime, 1)).to.be.revertedWith("too soon")
        await time.increase(DAY)
        await expect(sa.executePendingWithdrawal(startTime, 1)).to.be.revertedWith("too soon")
        await time.increase(7*DAY)
        expect(await sa.totalSupply()).to.eq(eth(2))
        await sa.connect(buyer).executePendingWithdrawal(startTime, 1)
        expect(await sa.balanceOf(buyer.address)).to.eq(0)
        expect(await sa.totalSupply()).to.eq(0)
        await sa.connect(seller).executePendingWithdrawal(2, 1) // fake withdrawals go through but send 0 eth
    })
})