// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolManager} from "v4-core/src/PoolManager.sol";
import {PositionManager} from "v4-periphery/src/PositionManager.sol";

abstract contract UniswapV4Config {
    struct UniswapV4Raw {
        address poolManager;
        address positionManager;
    }

    struct UniswapV4 {
        PoolManager poolManager;
        PositionManager positionManager;
    }

    function getChainConfig() internal view returns (UniswapV4 memory config) {
        UniswapV4Raw memory rawConfig = getRawChainConfig();
        config = UniswapV4({
            poolManager: PoolManager(rawConfig.poolManager),
            positionManager: PositionManager(payable(rawConfig.positionManager))
        });
    }

    function getRawChainConfig() internal view returns (UniswapV4Raw memory) {
        uint256 chainId = block.chainid;

        if (chainId == 130) {
            // Unichain Mainnet
            return UniswapV4Raw({
                poolManager: 0x1F98400000000000000000000000000000000004,
                positionManager: 0x4529A01c7A0410167c5740C487A8DE60232617bf
            });
        }

        if (chainId == 1) {
            // Ethereum Mainnet
            return UniswapV4Raw({
                poolManager: 0x000000000004444c5dc75cB358380D2e3dE08A90,
                positionManager: 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e
            });
        }

        if (chainId == 8453) {
            // Base Mainnet
            return UniswapV4Raw({
                poolManager: 0x498581fF718922c3f8e6A244956aF099B2652b2b,
                positionManager: 0x7C5f5A4bBd8fD63184577525326123B519429bDc
            });
        }

        if (chainId == 143) {
            // Monad Mainnet
            return UniswapV4Raw({
                poolManager: 0x188d586Ddcf52439676Ca21A244753fA19F9Ea8e,
                positionManager: 0x5b7eC4a94fF9beDb700fb82aB09d5846972F4016
            });
        }
        if (chainId == 4663) {
            // Robinhood Chain Mainnet
            return UniswapV4Raw({
                poolManager: 0x8366a39CC670B4001A1121B8F6A443A643e40951,
                positionManager: 0x58daec3116aae6D93017bAAea7749052E8a04fA7
            });
        }
        if (chainId == 196) {
            // X Layer Mainnet
            return UniswapV4Raw({
                poolManager: 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32,
                positionManager: 0xcF1EAFC6928dC385A342E7C6491d371d2871458b
            });
        }
        if (chainId == 137) {
            // Polygon Mainnet
            return UniswapV4Raw({
                poolManager: 0x67366782805870060151383F4BbFF9daB53e5cD6,
                positionManager: 0x1Ec2eBf4F37E7363FDfe3551602425af0B3ceef9
            });
        }
        if (chainId == 10) {
            // Optimism Mainnet
            return UniswapV4Raw({
                poolManager: 0x9a13F98Cb987694C9F086b1F5eB990EeA8264Ec3,
                positionManager: 0x3C3Ea4B57a46241e54610e5f022E5c45859A1017
            });
        }
        if (chainId == 42161) {
            // Arbitrum Mainnet
            return UniswapV4Raw({
                poolManager: 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32,
                positionManager: 0xd88F38F930b7952f2DB2432Cb002E7abbF3dD869
            });
        }
        if (chainId == 81457) {
            // Blast Mainnet
            return UniswapV4Raw({
                poolManager: 0x1631559198A9e474033433b2958daBC135ab6446,
                positionManager: 0x4AD2F4CcA2682cBB5B950d660dD458a1D3f1bAaD
            });
        }
        if (chainId == 7777777) {
            // Zora Mainnet
            return UniswapV4Raw({
                poolManager: 0x0575338e4C17006aE181B47900A84404247CA30f,
                positionManager: 0xf66C7b99e2040f0D9b326B3b7c152E9663543D63
            });
        }
        if (chainId == 480) {
            // World Chain Mainnet
            return UniswapV4Raw({
                poolManager: 0xb1860D529182ac3BC1F51Fa2ABd56662b7D13f33,
                positionManager: 0xC585E0f504613b5fBf874F21Af14c65260fB41fA
            });
        }
        if (chainId == 57073) {
            // Ink Mainnet
            return UniswapV4Raw({
                poolManager: 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32,
                positionManager: 0x1b35d13a2E2528f192637F14B05f0Dc0e7dEB566
            });
        }
        if (chainId == 1868) {
            // Soneium Mainnet
            return UniswapV4Raw({
                poolManager: 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32,
                positionManager: 0x1b35d13a2E2528f192637F14B05f0Dc0e7dEB566
            });
        }
        if (chainId == 43114) {
            // Avalanche Mainnet
            return UniswapV4Raw({
                poolManager: 0x06380C0e0912312B5150364B9DC4542BA0DbBc85,
                positionManager: 0xB74b1F14d2754AcfcbBe1a221023a5cf50Ab8ACD
            });
        }
        if (chainId == 56) {
            // BNB Mainnet
            return UniswapV4Raw({
                poolManager: 0x28e2Ea090877bF75740558f6BFB36A5ffeE9e9dF,
                positionManager: 0x7A4a5c919aE2541AeD11041A1AEeE68f1287f95b
            });
        }
        if (chainId == 42220) {
            // Celo Mainnet
            return UniswapV4Raw({
                poolManager: 0x288dc841A52FCA2707c6947B3A777c5E56cd87BC,
                positionManager: 0xf7965f3981e4D5BC383BfBCb61501763e9068CA9
            });
        }

        if (chainId == 1301) {
            // Unichain Sepolia
            return UniswapV4Raw({
                poolManager: 0x00B036B58a818B1BC34d502D3fE730Db729e62AC,
                positionManager: 0xf969Aee60879C54bAAed9F3eD26147Db216Fd664
            });
        }
        if (chainId == 11155111) {
            // Sepolia
            return UniswapV4Raw({
                poolManager: 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543,
                positionManager: 0x429ba70129df741B2Ca2a85BC3A2a3328e5c09b4
            });
        }
        if (chainId == 84532) {
            // Base Sepolia
            return UniswapV4Raw({
                poolManager: 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408,
                positionManager: 0x4B2C77d209D3405F41a037Ec6c77F7F5b8e2ca80
            });
        }
        if (chainId == 421614) {
            // Arbitrum Sepolia
            return UniswapV4Raw({
                poolManager: 0xFB3e0C6F74eB1a21CC1Da29aeC80D2Dfe6C9a317,
                positionManager: 0xAc631556d3d4019C95769033B5E719dD77124BAc
            });
        }
        if (chainId == 420120000) {
            // interop-alpha-0
            return UniswapV4Raw({
                poolManager: 0x9131B9084E6017Be19c6a0ef23f73dbB1Bf41f96,
                positionManager: 0x4498FE0b1DF6B476453440664A16E269B7587D0F
            });
        }
        if (chainId == 420120001) {
            // interop-alpha-1
            return UniswapV4Raw({
                poolManager: 0x9131B9084E6017Be19c6a0ef23f73dbB1Bf41f96,
                positionManager: 0x4498FE0b1DF6B476453440664A16E269B7587D0F
            });
        }
        revert("Unsupported chain");
    }
}
