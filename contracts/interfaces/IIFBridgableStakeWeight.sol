// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

interface IIFBridgableStakeWeight {
    enum BridgeType {
        UserWeight,
        TotalWeight
    }

    struct MessageRequest {
        // bridge type
        BridgeType bridgeType;
        // user address
        address user;
        // timestamp value
        uint80 timestamp;
        // amount of weight at timestamp
        uint192 weight;
        // track number
        uint24 trackId;
    }
}
