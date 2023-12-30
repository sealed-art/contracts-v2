import {
    time,
    loadFixture,
} from "@nomicfoundation/hardhat-toolbox/network-helpers";
import { expect } from "chai";
import { ethers, network } from "hardhat";

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
            const domain = {
                name: "SealedArtMarket",
                version: "1",
                chainId: chainIdHex,
                verifyingContract: contract ?? await sa.getAddress()
            };

            const signature = await signer.signTypedData(domain, types, value);
            const { r, s, v } = ethers.Signature.from(signature)
            return { r, s, v }
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

        /*
        const hf = (await ethers.getContractFactory("SealedFunding")).attach(hiddenFunding.predictedAddress) as any;
        await mockNFT.mint(buyer.address, 1)
        expect(await mockNFT.ownerOf(1)).to.equal(buyer.address)
        await mockNFT.connect(buyer).transferFrom(buyer.address, hiddenFunding.predictedAddress, 1)
        expect(await mockNFT.ownerOf(1)).to.equal(hiddenFunding.predictedAddress)
        await hf.retrieve(await mockNFT.getAddress(), 1)
        expect(await mockNFT.ownerOf(1)).to.equal(buyer.address)

        await mockToken.mint(hiddenFunding.predictedAddress, 10)
        expect(await mockToken.balanceOf(buyer.address)).to.eq(0)
        await hf.retrieve(await mockToken.getAddress(), 10)
        expect(await mockToken.balanceOf(buyer.address)).to.eq(10)
        */
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
        const types = {
            Bid: [
                { name: "auctionId", type: "bytes32" },
                { name: "maxAmount", type: "uint256" },
            ],
        };
        const value = {
            auctionId: auctionId,
            maxAmount: eth("2")
        };
        const bidSig = await sign(buyer, types, value, await auctions.getAddress())
        const seqVal = {
            auctionId: auctionId,
            amount: eth("1"),
            winner: buyer.address,
        }
        const seqSig = await sign(sequencer, {
            BidWinner: [
                { name: "auctionId", type: "bytes32" },
                { name: "amount", type: "uint256" },
                { name: "winner", type: "address" },
            ],
        }, seqVal, await auctions.getAddress())
        // Test that one salt being already revealed doesnt cause tx to revert
        const hiddenFunding2 = await fundingFactory.computeSealedFundingAddress(salt2, buyer.address)
        await buyer.sendTransaction({
            to: hiddenFunding2.predictedAddress,
            value: eth("0.1"),
        });
        await fundingFactory.deploySealedFunding(salt, buyer.address)
        await fundingFactory.deploySealedFunding(salt2, buyer.address)
        await auctions.settleAuctionWithSealedBids([salt2], seller.address, await mockNFT.getAddress(), SAMPLE_AUCTION_TYPE, 34, eth("1"), {
            ...bidSig, ...value,
        }, { ...seqSig, ...seqVal })
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