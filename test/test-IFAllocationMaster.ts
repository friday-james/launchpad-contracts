import '@nomiclabs/hardhat-ethers'
import { ethers, network } from 'hardhat'
import { expect } from 'chai'
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/signers'
import { Contract } from '@ethersproject/contracts'
import { mineNext } from './helpers'

export default describe('IFAllocationMaster', function () {
  // vars for all tests
  let owner: SignerWithAddress
  let nonOwner: SignerWithAddress
  let TestToken: Contract
  let IFAllocationMaster: Contract

  // setup for each test
  beforeEach(async () => {
    // get test accounts
    owner = (await ethers.getSigners())[0]
    nonOwner = (await ethers.getSigners())[1]

    // deploy test token
    const TestTokenFactory = await ethers.getContractFactory('TestToken')
    TestToken = await TestTokenFactory.deploy(
      'test token',
      'TEST',
      '21000000000000000000000000' // 21 million * 10**18
    )

    // deploy allocation master
    const IFAllocationMasterFactory = await ethers.getContractFactory(
      'IFAllocationMaster'
    )
    IFAllocationMaster = await IFAllocationMasterFactory.deploy()
  })

  // TESTS

  it('counts tracks', async () => {
    // num tracks should be 0
    mineNext()
    expect(await IFAllocationMaster.trackCount()).to.equal(0)

    // add a track
    mineNext()
    await IFAllocationMaster.addTrack('TEST Track', TestToken.address, 1000)

    // num tracks should be 1
    mineNext()
    expect(await IFAllocationMaster.trackCount()).to.equal(1)
  })

  it('can bump sale counter', async () => {
    // add a track
    mineNext()
    await IFAllocationMaster.addTrack('TEST Track', TestToken.address, 1000)
    const trackNum = 0

    // bump sale counter
    mineNext()
    await IFAllocationMaster.bumpSaleCounter(trackNum)
    mineNext()

    // update track as non-owner (should fail)
    mineNext()
    await IFAllocationMaster.connect(nonOwner).bumpSaleCounter(trackNum)
    mineNext()

    // sale counter should update only by owner
    const nCheckpoints = await IFAllocationMaster.trackCheckpointCounts(
      trackNum
    )
    const latestTrackCp = await IFAllocationMaster.trackCheckpoints(
      trackNum,
      nCheckpoints - 1
    )
    mineNext()
    expect(latestTrackCp.saleCounter).to.equal(1) // only 1 not 2
  })

  it('can disable track', async () => {
    // add a track
    mineNext()
    await IFAllocationMaster.addTrack('TEST Track', TestToken.address, 1000)
    const trackNum = 0

    // disable track as non-owner (should fail)
    mineNext()
    await IFAllocationMaster.connect(nonOwner).disableTrack(trackNum)
    mineNext()

    // try to stake (should work)
    await TestToken.approve(IFAllocationMaster.address, 100) // approve
    await IFAllocationMaster.stake(trackNum, 100) // stake
    mineNext()
    expect(await TestToken.balanceOf(IFAllocationMaster.address)).to.equal(100)

    // disable track as owner (should work)
    mineNext()
    await IFAllocationMaster.disableTrack(trackNum)
    mineNext()

    // try to stake (should not work)
    await TestToken.approve(IFAllocationMaster.address, 5) // approve
    await IFAllocationMaster.stake(trackNum, 5) // stake
    mineNext()
    expect(await TestToken.balanceOf(IFAllocationMaster.address)).to.equal(100)
  })

  it('accrues stake weight', async () => {
    // add a track
    mineNext()
    await IFAllocationMaster.addTrack(
      'TEST Track', // track name
      TestToken.address, // token
      '1000000000' // weight accrual rate
    )

    const trackNum = await IFAllocationMaster.trackCount()

    // how much to stake on a block-by-block basis
    const stakesOverTime = [
      '1000000000', // 1 gwei
      '0',
      '0',
      '0',
      '0',
      '50000000000', // 50 gwei
      '0',
      '0',
      '-50000000000', // -50 gwei
      '0',
      '0',
      '2500000000', // 2.5 gwei
      '0',
      '0',
      '0',
      '0',
      '0',
    ]

    //// block-by-block simulation

    // simulation data
    const simData = []
    // simulation starting block
    const simStartBlock = await ethers.provider.getBlockNumber()

    // simulation
    for (let i = 0; i < stakesOverTime.length; i++) {
      // owner stakes/unstakes according to stakesOverTime
      if (stakesOverTime[i] !== '0' && stakesOverTime[i][0] !== '-') {
        // approve
        await TestToken.approve(IFAllocationMaster.address, stakesOverTime[i])
        // stake
        await IFAllocationMaster.stake(trackNum, stakesOverTime[i])
      } else if (stakesOverTime[i] !== '0' && stakesOverTime[i][0] === '-') {
        // unstake
        await IFAllocationMaster.unstake(
          trackNum,
          stakesOverTime[i].substring(1)
        )
      }

      mineNext()

      // current block number
      const currBlock = await ethers.provider.getBlockNumber()

      // user's staked amount
      const nCheckpoints = await IFAllocationMaster.userCheckpointCounts(
        trackNum,
        owner.address
      )
      const checkpoint = await IFAllocationMaster.userCheckpoints(
        trackNum,
        owner.address,
        nCheckpoints - 1
      )

      // get current stake
      simData.push({
        block: currBlock,
        userStake: checkpoint.staked,
        userWeight: await IFAllocationMaster.getUserStakeWeight(
          trackNum,
          owner.address,
          currBlock
        ),
        totalWeight: await IFAllocationMaster.getTotalStakeWeight(
          trackNum,
          currBlock
        ),
      })
    }

    // print simulation data
    console.log('Simulation data')
    simData.map(async (row) => {
      console.log(
        'Block',
        (row.block - simStartBlock).toString(),
        '| User stake',
        row.userStake.toString(),
        '| User weight',
        row.userWeight.toString(),
        '| Total weight',
        row.totalWeight.toString()
      )
    })

    // print track checkpoints
    console.log('\nTrack checkpoints')
    const nTrackCheckpoints = await IFAllocationMaster.trackCheckpointCounts(
      trackNum
    )
    for (let i = 0; i < nTrackCheckpoints; i++) {
      const checkpoint = await IFAllocationMaster.trackCheckpoints(trackNum, i)
      console.log(
        'Block',
        (checkpoint.blockNumber - simStartBlock).toString(),
        '| Total staked',
        checkpoint.totalStaked.toString(),
        '| Total stake weight',
        checkpoint.totalStakeWeight.toString()
      )
    }
  })
})