import { mineNext, setAutomine } from './helpers'
import { ethers } from 'hardhat'
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/signers'
import { Contract } from '@ethersproject/contracts'
import { BigNumber } from '@ethersproject/bignumber'

interface SimInputRow {
  stakeAmounts?: string[]
  bumpSaleCounter?: boolean
  disableTrack?: boolean
  emergencyWithdraws?: boolean[]
  activeRollOvers?: boolean[]
  label?: string
}

interface SimOutputRow {
  block: number
  user1Stake: BigNumber
  user1Weight: BigNumber
  user1SaleCount: number
  totalWeight: BigNumber
  trackSaleCount: number
  gasUsed: BigNumber
}

export const simAllocationMaster = async (
  allocationMaster: Contract,
  stakeToken: Contract,
  trackNum: number,
  simUsers: SignerWithAddress[],
  simInput: SimInputRow[]
): Promise<SimOutputRow[]> => {
  const simOutput = []
  await setAutomine(false)
  // simulation
  for (let i = 0; i < simInput.length; i++) {
    // disable track if specified
    if (simInput[i].disableTrack) {
      await allocationMaster.disableTrack(trackNum)
    }

    // bump sale counter if specified
    if (simInput[i].bumpSaleCounter) {
      await allocationMaster.bumpSaleCounter(trackNum)
    }

    // perform active rollover if specified
    const activeRollovers = simInput[i].activeRollOvers
    if (activeRollovers) {
      for (let j = 0; j < activeRollovers.length; j++)
        activeRollovers[j] &&
          (await allocationMaster.connect(simUsers[j]).activeRollOver(trackNum))
    }

    // emergency withdraw if specified
    const emergencyWithdraws = simInput[i].emergencyWithdraws
    if (emergencyWithdraws) {
      for (let j = 0; j < emergencyWithdraws.length; j++)
        emergencyWithdraws[j] &&
          (await allocationMaster
            .connect(simUsers[j])
            .emergencyWithdraw(trackNum))
    }

    // user stakes/unstakes according to stakesOverTime
    const stakeAmounts = simInput[i].stakeAmounts
    if (stakeAmounts) {
      for (let j = 0; j < stakeAmounts.length; j++) {
        const amount = stakeAmounts[j]
        const user = simUsers[j]

        if (amount !== '0' && amount[0] !== '-') {
          // approve
          await stakeToken
            .connect(user)
            .approve(allocationMaster.address, amount)
          // stake
          await allocationMaster.connect(user).stake(trackNum, amount)
        } else if (amount !== '0' && amount[0] === '-') {
          // unstake
          await allocationMaster
            .connect(user)
            .unstake(trackNum, amount.substring(1))
        }
      }
    }

    mineNext()

    // current block number
    const currBlockNum = await ethers.provider.getBlockNumber()

    // current block
    const currBlock = await ethers.provider.getBlock(currBlockNum)

    // gas used
    const gasUsed = currBlock.gasUsed

    // max stakes
    const trackMaxStakes = await allocationMaster.trackMaxStakes(trackNum)

    // get track checkpoint
    const nTrackCheckpoints = await allocationMaster.trackCheckpointCounts(
      trackNum
    )
    const trackCp = await allocationMaster.trackCheckpoints(
      trackNum,
      nTrackCheckpoints - 1
    )

    // get checkpoints of users
    const user1Checkpoints = await allocationMaster.userCheckpointCounts(
      trackNum,
      simUsers[0].address
    )
    const user2Checkpoints = await allocationMaster.userCheckpointCounts(
      trackNum,
      simUsers[1].address
    )
    const user1Cp = await allocationMaster.userCheckpoints(
      trackNum,
      simUsers[0].address,
      user1Checkpoints - 1
    )
    const user2Cp = await allocationMaster.userCheckpoints(
      trackNum,
      simUsers[1].address,
      user2Checkpoints - 1
    )

    // save data row
    simOutput.push({
      block: currBlockNum,
      user1Stake: user1Cp.staked,
      user1Weight: await allocationMaster.getUserStakeWeight(
        trackNum,
        simUsers[0].address,
        currBlock.timestamp
      ),
      user1SaleCount: user1Cp.numFinishedSales,
      user1Balance: await stakeToken.balanceOf(simUsers[0].address),
      user2Stake: user2Cp.staked,
      user2Weight: await allocationMaster.getUserStakeWeight(
        trackNum,
        simUsers[1].address,
        currBlock.timestamp
      ),
      user2SaleCount: user2Cp.numFinishedSales,
      user2Balance: await stakeToken.balanceOf(simUsers[1].address),
      totalWeight: await allocationMaster.getTotalStakeWeight(
        trackNum,
        currBlock.timestamp
      ),
      trackSaleCount: trackCp.numFinishedSales,
      trackMaxStakes,
      gasUsed: gasUsed,
    })
  }
  await setAutomine(true)
  return simOutput
}
