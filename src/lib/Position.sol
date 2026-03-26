// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.27;

library Position {
    struct Info {
        // the amount of liquidity owned by this position
        uint128 liquidity;
        // fee growth per unit of liquidity as of the last update to liquidity or fees owed
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
        // the fees owed to the position owner in token0/token1
        uint128 tokensOwed0;
        uint128 tokensOwed1;
    }

    function get(mapping(bytes32 => Info) storage self, address owner, int24 tickLower, int24 tickUpper)
        internal
        view
        returns (Info storage position)
    {
        position = self[keccak256(abi.encodePacked(owner, tickLower, tickUpper))];
    }

    function update(Info storage self, int128 liquidityDelta, uint256, uint256) internal {
        Info memory _self = self;

        if (liquidityDelta == 0) {
            // disallow pokes for 0 liquidity positions
            require(_self.liquidity > 0);
        }

        if (liquidityDelta < 0) {
            // forge-lint: disable-next-line(unsafe-typecast)
            self.liquidity = _self.liquidity - uint128(-liquidityDelta);
        } else {
            // forge-lint: disable-next-line(unsafe-typecast)
            self.liquidity = _self.liquidity + uint128(liquidityDelta);
        }
    }
}
