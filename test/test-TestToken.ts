import '@nomiclabs/hardhat-ethers'
import { ethers } from 'hardhat'
import { expect } from 'chai'

export default describe('TestToken', function () {
  it('sets starting supply', async function () {
    // get owner
    const [owner] = await ethers.getSigners()

    // parameters
    const startingSupply = 21_000_000_000

    // deploy
    const TestTokenFactory = await ethers.getContractFactory('TestToken')
    const TestToken = await TestTokenFactory.deploy(
      'test token',
      'TEST',
      startingSupply
    )

    // test
    expect(await TestToken.balanceOf(owner.address)).to.equal(startingSupply)
  })
})