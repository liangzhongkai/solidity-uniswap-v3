// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.27;

import {BitMath} from "./BitMath.sol";
import {SafeCast} from "./SafeCast.sol";

library TickBitmap {
    // -2**23 <= int24 <= 2**23 - 1
    function position(int24 tick) private pure returns (int16 wordPos, uint8 bitPos) {
        return SafeCast.tickBitmapPosition(tick);
    }

    function flipTick(mapping(int16 => uint256) storage self, int24 tick, int24 tickSpacing) internal {
        require(tick % tickSpacing == 0);
        (int16 wordPos, uint8 bitPos) = position(tick / tickSpacing);
        // 0 <= uint8 <= 2**8 - 1 = 255
        // mask = 1 at bit position, rest are 0
        uint256 mask = uint256(1) << bitPos;
        // xor
        self[wordPos] ^= mask;
    }

    function nextInitializedTickWithinOneWord(
        mapping(int16 => uint256) storage self,
        int24 tick,
        int24 tickSpacing,
        // true = 向左（更小或相等）搜索
        bool lte
    ) internal view returns (int24 next, bool initialized) {
        int24 compressed = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) {
            compressed--;
        }

        if (lte) {
            (int16 wordPos, uint8 bitPos) = position(compressed);

            uint256 oneAt = uint256(1) << bitPos;
            uint256 mask = oneAt - 1 + oneAt;
            uint256 masked = self[wordPos] & mask;

            initialized = masked != 0;

            next = initialized
                ? (compressed - int24(uint24(bitPos - BitMath.mostSignificantBit(masked)))) * tickSpacing
                : (compressed - int24(uint24(bitPos))) * tickSpacing;
        } else {
            (int16 wordPos, uint8 bitPos) = position(compressed + 1);

            uint256 oneAt = uint256(1) << bitPos;
            uint256 mask = ~(oneAt - 1);
            uint256 masked = self[wordPos] & mask;

            initialized = masked != 0;

            next = initialized
                ? (compressed + 1 + int24(uint24(BitMath.leastSignificantBit(masked) - bitPos))) * tickSpacing
                : (compressed + 1 + int24(uint24(type(uint8).max - bitPos))) * tickSpacing;
        }
    }
}
