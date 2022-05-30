// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import './interfaces/IIFRetrievableStakeWeight.sol';
import './interfaces/IIFBridgableStakeWeight.sol';

contract IFAllocationMasterAdapter is
    IIFRetrievableStakeWeight,
    IIFBridgableStakeWeight
{
    // Celer Multichain Integration
    address messageBus;

    // Whitelisted Caller
    address srcAddress;
    uint24 srcChainId;

    // user checkpoint mapping -- (track, user address, timestamp) => UserStakeWeight
    mapping(uint24 => mapping(address => mapping(uint80 => uint192)))
        public userStakeWeights;

    // user checkpoint mapping -- (track, timestamp) => TotalStakeWeight
    mapping(uint24 => mapping(uint80 => uint192)) public totalStakeWeight;

    // MODIFIERS
    modifier onlyMessageBus() {
        require(msg.sender == messageBus, 'caller is not message bus');
        _;
    }

    // CONSTRUCTOR
    constructor(
        _messageBus,
        _srcAddress,
        _srcChainId
    ) {
        messageBus = _messageBus;
        srcAddress = srcAddress;
        srcChainId = srcChainId;
    }

    function getTotalStakeWeight(uint24 trackId, uint80 timestamp)
        external
        view
        returns (uint192)
    {
        return totalStakeWeight[trackId][timestamp];
    }

    function getUserStakeWeight(
        uint24 trackId,
        address user,
        uint80 timestamp
    ) public view returns (uint192) {
        return userStakeWeights[trackId][user][timestamp];
    }

    // Bridge functionalities

    /**
     * execute the bridged message sent by messageBus
     * @notice Called by MessageBus (MessageBusReceiver)
     * @param _sender The address of the source app contract
     * @param _srcChainId The source chain ID where the transfer is originated from
     * @param _message Arbitrary message bytes originated from and encoded by the source app contract
     * @param _executor Address who called the MessageBus execution function
     */
    function executeMessage(
        address _sender,
        uint64 _srcChainId,
        bytes calldata _message,
        address _executor
    ) external onlyMessageBus returns (IMessageReceiverApp.ExecutionStatus) {
        // sender has to be source master address
        require(_sender == srcAddress, 'sender != srcAddress');

        // srcChainId has to be the same as source chain id
        require(_srcChainId == srcChainId, 'srcChainId != _srcChainId');

        // decode the message
        MessageRequest memory message = abi.decode(
            (_message),
            (MessageRequest)
        );

        if (message.bridgeType == BridgeType.UserWeight) {
            userStakeWeights[message.trackId][message.user][
                message.timestamp
            ] = message.weight;
        } else {
            totalStakeWeight[message.trackId][message.timestamp] = message
            .weight;
        }

        return IMessageReceiverApp.ExecutionStatus.Success;
    }
}
