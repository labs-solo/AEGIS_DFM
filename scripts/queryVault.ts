import { ethers } from 'ethers'

async function main() {
  const vault = new ethers.Contract(process.argv[2], [], new ethers.providers.JsonRpcProvider(process.argv[3]))
  const pol = await vault.totalPolShares()
  const badDebt = await vault.badDebt()
  console.log('POL', pol.toString())
  console.log('BadDebt', badDebt.toString())
}

main()
