// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.27;

// Copied from https://github.com/Uniswap/v4-core

/// @title Safe casting methods
/// @notice Contains methods for safely casting between types
// forge-lint: disable-start(unsafe-typecast)
library SafeCast {
    /// @notice Cast a uint256 to a uint160, revert on overflow
    /// @param y The uint256 to be downcasted
    /// @return z The downcasted integer, now type uint160
    function toUint160(uint256 y) internal pure returns (uint160 z) {
        require((z = uint160(y)) == y);
    }

    /// @notice Cast a int256 to a int128, revert on overflow or underflow
    /// @param y The int256 to be downcasted
    /// @return z The downcasted integer, now type int128
    function toInt128(int256 y) internal pure returns (int128 z) {
        require((z = int128(y)) == y);
    }

    /// @notice Cast a uint256 to a int256, revert on overflow
    /// @param y The uint256 to be casted
    /// @return z The casted integer, now type int256
    function toInt256(uint256 y) internal pure returns (int256 z) {
        require(y <= uint256(type(int256).max));
        z = int256(y);
    }

    /// @notice Cast a uint256 to a int128, revert on overflow
    /// @param y The uint256 to be downcasted
    /// @return z The downcasted integer, now type int128
    function toInt128(uint256 y) internal pure returns (int128 z) {
        require(y <= uint128(type(int128).max));
        z = int128(int256(y));
    }

    /// @notice Absolute value of int128 as uint128; reverts if |y| does not fit uint128
    function absAsUint128(int128 y) internal pure returns (uint128 z) {
        int256 yi = int256(y);
        uint256 mag = yi < 0 ? uint256(-yi) : uint256(yi);
        require(mag <= uint256(type(uint128).max));
        z = uint128(mag);
    }

    /// @notice Cast uint256 to uint128; reverts on overflow
    function toUint128(uint256 y) internal pure returns (uint128 z) {
        require((z = uint128(y)) == y);
    }

    /// @notice Cast non-negative int256 to uint256
    function toUint256(int256 y) internal pure returns (uint256 z) {
        require(y >= 0);
        unchecked {
            z = uint256(y);
        }
    }

    /// @notice Magnitude of non-positive int256 as uint256
    function negToUint256(int256 y) internal pure returns (uint256 z) {
        require(y <= 0);
        unchecked {
            z = uint256(-y);
        }
    }

    /// @notice Cast non-negative int128 to uint128
    function toUint128(int128 y) internal pure returns (uint128 z) {
        require(y >= 0);
        unchecked {
            z = uint128(uint256(int256(y)));
        }
    }

    /// @notice Word and bit index for tick bitmap (matches Uniswap V3 TickBitmap.position)
    function tickBitmapPosition(int24 tick) internal pure returns (int16 wordPos, uint8 bitPos) {
        wordPos = int16(tick >> 8);
        bitPos = uint8(uint24(tick % 256));
    }
}
// forge-lint: disable-end(unsafe-typecast)
