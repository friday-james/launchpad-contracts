//SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import '@openzeppelin/contracts/access/Ownable.sol';
import '@openzeppelin/contracts/security/ReentrancyGuard.sol';

// IFAllocationMaster is responsible for persisting all launchpad state between project token sales
// in order for the sales to have clean, self-enclosed, one-time-use states.

// IFAllocationMaster is the master of allocations. He can remember everything and he is a smart guy.
contract IFAllocationMaster is Ownable, ReentrancyGuard {
    using SafeERC20 for ERC20;

    // CONSTANTS

    // number of decimals of rollover factors
    uint64 constant ROLLOVER_FACTOR_DECIMALS = 10**18;

    // STRUCTS

    // A checkpoint for marking stake info at a given block
    struct UserCheckpoint {
        // block number of checkpoint
        uint80 blockNumber;
        // amount staked at checkpoint
        uint104 staked;
        // amount of stake weight at checkpoint
        uint192 stakeWeight;
        // number of finished sales at time of checkpoint
        uint24 numFinishedSales;
    }

    // A checkpoint for marking stake info at a given block
    struct TrackCheckpoint {
        // block number of checkpoint
        uint80 blockNumber;
        // amount staked at checkpoint
        uint104 totalStaked;
        // amount of stake weight at checkpoint
        uint192 totalStakeWeight;
        // number of finished sales at time of checkpoint
        uint24 numFinishedSales;
        // whether track is disabled (once disabled, cannot undo)
        bool disabled;
    }

    // Info of each track. These parameters cannot be changed.
    struct TrackInfo {
        // name of track
        string name;
        // token to stake (e.g., IDIA)
        ERC20 stakeToken;
        // weight accrual rate for this track (stake weight increase per block per stake token)
        uint24 weightAccrualRate;
        // amount rolled over when finished sale counter increases (with decimals == ROLLOVER_FACTOR_DECIMALS)
        // e.g., if rolling over 20% when sale finishes, then this is 0.2 * ROLLOVER_FACTOR_DECIMALS, or
        // 200_000_000_000_000_000
        uint64 passiveRolloverRate;
        // amount rolled over when finished sale counter increases, and user actively elected to roll over
        uint64 activeRolloverRate;
        // maximum total stake for a user in this track
        uint104 maxTotalStake;
    }

    // INFO FOR FACTORING IN ROLLOVERS

    // the number of checkpoints of a track -- (track, finished sale count) => block number
    mapping(uint24 => mapping(uint24 => uint80)) public trackFinishedSaleBlocks;

    // stake weight each user actively rolls over for a given track and a finished sale count
    // (track, user, finished sale count) => amount of stake weight
    mapping(uint24 => mapping(address => mapping(uint24 => uint192)))
        public trackActiveRollOvers;

    // total stake weight actively rolled over for a given track and a finished sale count
    // (track, finished sale count) => total amount of stake weight
    mapping(uint24 => mapping(uint24 => uint192))
        public trackTotalActiveRollOvers;

    // TRACK INFO

    // array of track information
    TrackInfo[] public tracks;

    // array of unique stakers on track
    // users are only added on first checkpoint to maintain unique
    mapping(uint24 => address[]) public trackStakers;

    // the number of checkpoints of a track -- (track) => checkpoint count
    mapping(uint24 => uint32) public trackCheckpointCounts;

    // track checkpoint mapping -- (track, checkpoint number) => TrackCheckpoint
    mapping(uint24 => mapping(uint32 => TrackCheckpoint))
        public trackCheckpoints;

    // USER INFO

    // the number of checkpoints of a user for a track -- (track, user address) => checkpoint count
    mapping(uint24 => mapping(address => uint32)) public userCheckpointCounts;

    // user checkpoint mapping -- (track, user address, checkpoint number) => UserCheckpoint
    mapping(uint24 => mapping(address => mapping(uint32 => UserCheckpoint)))
        public userCheckpoints;

    // EVENTS

    event AddTrack(string indexed name, address indexed token);
    event DisableTrack(uint24 indexed trackId);
    event ActiveRollOver(uint24 indexed trackId, address indexed user);
    event BumpSaleCounter(uint24 indexed trackId, uint32 newCount);
    event AddUserCheckpoint(uint24 indexed trackId, uint80 blockNumber);
    event AddTrackCheckpoint(uint24 indexed trackId, uint80 blockNumber);
    event Stake(uint24 indexed trackId, address indexed user, uint104 amount);
    event Unstake(uint24 indexed trackId, address indexed user, uint104 amount);
    event EmergencyTokenRetrieve(address indexed sender, uint256 amount);

    // CONSTRUCTOR

    constructor() {}

    // FUNCTIONS

    // number of tracks
    function trackCount() external view returns (uint24) {
        return uint24(tracks.length);
    }

    // adds a new track
    function addTrack(
        string calldata name,
        ERC20 stakeToken,
        uint24 _weightAccrualRate,
        uint64 _passiveRolloverRate,
        uint64 _activeRolloverRate,
        uint104 _maxTotalStake
    ) external onlyOwner {
        require(_weightAccrualRate != 0, 'accrual rate is 0');

        // add track
        tracks.push(
            TrackInfo({
                name: name, // name of track
                stakeToken: stakeToken, // token to stake (e.g., IDIA)
                weightAccrualRate: _weightAccrualRate, // rate of stake weight accrual
                passiveRolloverRate: _passiveRolloverRate, // passive rollover
                activeRolloverRate: _activeRolloverRate, // active rollover
                maxTotalStake: _maxTotalStake // max total stake
            })
        );

        // add first track checkpoint
        addTrackCheckpoint(
            uint24(tracks.length - 1), // latest track
            0, // initialize with 0 stake
            false, // add or sub does not matter
            false, // initialize as not disabled
            false // do not bump finished sale counter
        );

        // emit
        emit AddTrack(name, address(stakeToken));
    }

    // bumps a track's finished sale counter
    function bumpSaleCounter(uint24 trackId) external onlyOwner {
        // get number of finished sales of this track
        uint24 nFinishedSales = trackCheckpoints[trackId][
            trackCheckpointCounts[trackId] - 1
        ]
        .numFinishedSales;

        // update map that tracks block numbers of finished sales
        trackFinishedSaleBlocks[trackId][nFinishedSales] = uint80(block.number);

        // add a new checkpoint with counter incremented by 1
        addTrackCheckpoint(trackId, 0, false, false, true);

        // `BumpSaleCounter` event emitted in function call above
    }

    // disables a track
    function disableTrack(uint24 trackId) external onlyOwner {
        // add a new checkpoint with `disabled` set to true
        addTrackCheckpoint(trackId, 0, false, true, false);

        // `DisableTrack` event emitted in function call above
    }

    // perform active rollover
    function activeRollOver(uint24 trackId) external {
        // add new user checkpoint
        addUserCheckpoint(trackId, 0, false);

        // get new user checkpoint
        UserCheckpoint memory userCp = userCheckpoints[trackId][_msgSender()][
            userCheckpointCounts[trackId][_msgSender()] - 1
        ];

        // current sale count
        uint24 saleCount = userCp.numFinishedSales;

        // subtract old user rollover amount from total
        trackTotalActiveRollOvers[trackId][saleCount] -= trackActiveRollOvers[
            trackId
        ][_msgSender()][saleCount];

        // update user rollover amount
        trackActiveRollOvers[trackId][_msgSender()][saleCount] = userCp
        .stakeWeight;

        // add new user rollover amount to total
        trackTotalActiveRollOvers[trackId][saleCount] += userCp.stakeWeight;

        // emit
        emit ActiveRollOver(trackId, _msgSender());
    }

    // get closest PRECEDING user checkpoint
    function getClosestUserCheckpoint(
        uint24 trackId,
        address user,
        uint80 blockNumber
    ) private view returns (UserCheckpoint memory cp) {
        // get total checkpoint count for user
        uint32 nCheckpoints = userCheckpointCounts[trackId][user];

        if (
            userCheckpoints[trackId][user][nCheckpoints - 1].blockNumber <=
            blockNumber
        ) {
            // First check most recent checkpoint

            // return closest checkpoint
            return userCheckpoints[trackId][user][nCheckpoints - 1];
        } else if (
            userCheckpoints[trackId][user][0].blockNumber > blockNumber
        ) {
            // Next check earliest checkpoint

            // If specified block number is earlier than user's first checkpoint,
            // return null checkpoint
            return
                UserCheckpoint({
                    blockNumber: 0,
                    staked: 0,
                    stakeWeight: 0,
                    numFinishedSales: 0
                });
        } else {
            // binary search on checkpoints
            uint32 lower = 0;
            uint32 upper = nCheckpoints - 1;
            while (upper > lower) {
                uint32 center = upper - (upper - lower) / 2; // ceil, avoiding overflow
                UserCheckpoint memory tempCp = userCheckpoints[trackId][user][
                    center
                ];
                if (tempCp.blockNumber == blockNumber) {
                    return tempCp;
                } else if (tempCp.blockNumber < blockNumber) {
                    lower = center;
                } else {
                    upper = center - 1;
                }
            }

            // return closest checkpoint
            return userCheckpoints[trackId][user][lower];
        }
    }

    // gets a user's stake weight within a track at a particular block number
    // logic extended from Compound COMP token `getPriorVotes` function
    function getUserStakeWeight(
        uint24 trackId,
        address user,
        uint80 blockNumber
    ) public view returns (uint192) {
        require(blockNumber <= block.number, 'block # too high');

        // check number of user checkpoints
        uint32 nUserCheckpoints = userCheckpointCounts[trackId][user];
        if (nUserCheckpoints == 0) {
            return 0;
        }

        // get closest preceding user checkpoint
        UserCheckpoint memory closestUserCheckpoint = getClosestUserCheckpoint(
            trackId,
            user,
            blockNumber
        );

        // check if closest preceding checkpoint was null checkpoint
        if (closestUserCheckpoint.blockNumber == 0) {
            return 0;
        }

        // get closest preceding track checkpoint

            TrackCheckpoint memory closestTrackCheckpoint
         = getClosestTrackCheckpoint(trackId, blockNumber);

        // get number of finished sales between user's last checkpoint blockNumber and provided blockNumber
        uint24 numFinishedSalesDelta = closestTrackCheckpoint.numFinishedSales -
            closestUserCheckpoint.numFinishedSales;

        // get track info
        TrackInfo memory track = tracks[trackId];

        // calculate stake weight given above delta
        uint192 stakeWeight;
        if (numFinishedSalesDelta == 0) {
            // calculate normally without rollover decay

            uint80 elapsedBlocks = blockNumber -
                closestUserCheckpoint.blockNumber;

            stakeWeight =
                closestUserCheckpoint.stakeWeight +
                (uint192(elapsedBlocks) *
                    track.weightAccrualRate *
                    closestUserCheckpoint.staked) /
                10**18;

            return stakeWeight;
        } else {
            // calculate with rollover decay

            // starting stakeweight
            stakeWeight = closestUserCheckpoint.stakeWeight;
            // current block for iteration
            uint80 currBlock = closestUserCheckpoint.blockNumber;

            // for each finished sale in between, get stake weight of that period
            // and perform weighted sum
            for (uint24 i = 0; i < numFinishedSalesDelta; i++) {
                // get number of blocks passed at the current sale number
                uint80 elapsedBlocks = trackFinishedSaleBlocks[trackId][
                    closestUserCheckpoint.numFinishedSales + i
                ] - currBlock;

                // update stake weight
                stakeWeight =
                    stakeWeight +
                    (uint192(elapsedBlocks) *
                        track.weightAccrualRate *
                        closestUserCheckpoint.staked) /
                    10**18;

                // get amount of stake weight actively rolled over for this sale number
                uint192 activeRolloverWeight = trackActiveRollOvers[trackId][
                    user
                ][closestUserCheckpoint.numFinishedSales + i];

                // factor in passive and active rollover decay
                stakeWeight =
                    // decay active weight
                    (activeRolloverWeight * track.activeRolloverRate) /
                    ROLLOVER_FACTOR_DECIMALS +
                    // decay passive weight
                    ((stakeWeight - activeRolloverWeight) *
                        track.passiveRolloverRate) /
                    ROLLOVER_FACTOR_DECIMALS;

                // update currBlock for next round
                currBlock = trackFinishedSaleBlocks[trackId][
                    closestUserCheckpoint.numFinishedSales + i
                ];
            }

            // add any remaining accrued stake weight at current finished sale count
            uint80 remainingElapsed = blockNumber -
                trackFinishedSaleBlocks[trackId][
                    closestTrackCheckpoint.numFinishedSales - 1
                ];
            stakeWeight +=
                (uint192(remainingElapsed) *
                    track.weightAccrualRate *
                    closestUserCheckpoint.staked) /
                10**18;
        }

        // return
        return stakeWeight;
    }

    // get closest PRECEDING track checkpoint
    function getClosestTrackCheckpoint(uint24 trackId, uint80 blockNumber)
        private
        view
        returns (TrackCheckpoint memory cp)
    {
        // get total checkpoint count for track
        uint32 nCheckpoints = trackCheckpointCounts[trackId];

        if (
            trackCheckpoints[trackId][nCheckpoints - 1].blockNumber <=
            blockNumber
        ) {
            // First check most recent checkpoint

            // return closest checkpoint
            return trackCheckpoints[trackId][nCheckpoints - 1];
        } else if (trackCheckpoints[trackId][0].blockNumber > blockNumber) {
            // Next check earliest checkpoint

            // If specified block number is earlier than track's first checkpoint,
            // return null checkpoint
            return
                TrackCheckpoint({
                    blockNumber: 0,
                    totalStaked: 0,
                    totalStakeWeight: 0,
                    disabled: false,
                    numFinishedSales: 0
                });
        } else {
            // binary search on checkpoints
            uint32 lower = 0;
            uint32 upper = nCheckpoints - 1;
            while (upper > lower) {
                uint32 center = upper - (upper - lower) / 2; // ceil, avoiding overflow
                TrackCheckpoint memory tempCp = trackCheckpoints[trackId][
                    center
                ];
                if (tempCp.blockNumber == blockNumber) {
                    return tempCp;
                } else if (tempCp.blockNumber < blockNumber) {
                    lower = center;
                } else {
                    upper = center - 1;
                }
            }

            // return closest checkpoint
            return trackCheckpoints[trackId][lower];
        }
    }

    // gets total stake weight within a track at a particular block number
    // logic extended from Compound COMP token `getPriorVotes` function
    function getTotalStakeWeight(uint24 trackId, uint80 blockNumber)
        external
        view
        returns (uint192)
    {
        require(blockNumber <= block.number, 'block # too high');

        // get closest track checkpoint
        TrackCheckpoint memory closestCheckpoint = getClosestTrackCheckpoint(
            trackId,
            blockNumber
        );

        // check if closest preceding checkpoint was null checkpoint
        if (closestCheckpoint.blockNumber == 0) {
            return 0;
        }

        // calculate blocks elapsed since checkpoint
        uint80 additionalBlocks = (blockNumber - closestCheckpoint.blockNumber);

        // get track info
        TrackInfo storage trackInfo = tracks[trackId];

        // calculate marginal accrued stake weight
        uint192 marginalAccruedStakeWeight = (uint192(additionalBlocks) *
            trackInfo.weightAccrualRate *
            closestCheckpoint.totalStaked) / 10**18;

        // return
        return closestCheckpoint.totalStakeWeight + marginalAccruedStakeWeight;
    }

    function addUserCheckpoint(
        uint24 trackId,
        uint104 amount,
        bool addElseSub
    ) internal {
        // get track info
        TrackInfo storage track = tracks[trackId];

        // get user checkpoint count
        uint32 nCheckpointsUser = userCheckpointCounts[trackId][_msgSender()];

        // get track checkpoint count
        uint32 nCheckpointsTrack = trackCheckpointCounts[trackId];

        // get latest track checkpoint
        TrackCheckpoint memory trackCp = trackCheckpoints[trackId][
            nCheckpointsTrack - 1
        ];

        // if this is first checkpoint
        if (nCheckpointsUser == 0) {
            // check if amount exceeds maximum
            require(amount <= track.maxTotalStake, 'exceeds staking cap');

            // add user to stakers list of track
            trackStakers[trackId].push(_msgSender());

            // add a first checkpoint for this user on this track
            userCheckpoints[trackId][_msgSender()][0] = UserCheckpoint({
                blockNumber: uint80(block.number),
                staked: amount,
                stakeWeight: 0,
                numFinishedSales: trackCp.numFinishedSales
            });

            // increment user's checkpoint count
            userCheckpointCounts[trackId][_msgSender()] = nCheckpointsUser + 1;
        } else {
            // get previous checkpoint
            UserCheckpoint storage prev = userCheckpoints[trackId][
                _msgSender()
            ][nCheckpointsUser - 1];

            // check if amount exceeds maximum
            require(
                (addElseSub ? prev.staked + amount : prev.staked - amount) <=
                    track.maxTotalStake,
                'exceeds staking cap'
            );

            // ensure block number downcast to uint80 is monotonically increasing (prevent overflow)
            // this should never happen within the lifetime of the universe, but if it does, this prevents a catastrophe
            require(
                prev.blockNumber <= uint80(block.number),
                'block # overflow'
            );

            // add a new checkpoint for user within this track
            // if no blocks elapsed, just update prev checkpoint (so checkpoints can be uniquely identified by block number)
            if (prev.blockNumber == uint80(block.number)) {
                prev.staked = addElseSub
                    ? prev.staked + amount
                    : prev.staked - amount;
                prev.numFinishedSales = trackCp.numFinishedSales;
            } else {
                userCheckpoints[trackId][_msgSender()][
                    nCheckpointsUser
                ] = UserCheckpoint({
                    blockNumber: uint80(block.number),
                    staked: addElseSub
                        ? prev.staked + amount
                        : prev.staked - amount,
                    stakeWeight: getUserStakeWeight(
                        trackId,
                        _msgSender(),
                        uint80(block.number)
                    ),
                    numFinishedSales: trackCp.numFinishedSales
                });

                // increment user's checkpoint count
                userCheckpointCounts[trackId][_msgSender()] =
                    nCheckpointsUser +
                    1;
            }
        }

        // emit
        emit AddUserCheckpoint(trackId, uint80(block.number));
    }

    function addTrackCheckpoint(
        uint24 trackId, // track number
        uint104 amount, // delta on staked amount
        bool addElseSub, // true = adding; false = subtracting
        bool disabled, // whether track is disabled; cannot undo a disable
        bool _bumpSaleCounter // whether to increase sale counter by 1
    ) internal {
        // get track info
        TrackInfo storage track = tracks[trackId];

        // get track checkpoint count
        uint32 nCheckpoints = trackCheckpointCounts[trackId];

        // if this is first checkpoint
        if (nCheckpoints == 0) {
            // add a first checkpoint for this track
            trackCheckpoints[trackId][0] = TrackCheckpoint({
                blockNumber: uint80(block.number),
                totalStaked: amount,
                totalStakeWeight: 0,
                disabled: disabled,
                numFinishedSales: _bumpSaleCounter ? 1 : 0
            });

            // increase new track's checkpoint count by 1
            trackCheckpointCounts[trackId]++;
        } else {
            // get previous checkpoint
            TrackCheckpoint storage prev = trackCheckpoints[trackId][
                nCheckpoints - 1
            ];

            if (prev.disabled) {
                // if previous checkpoint was disabled, then disabled cannot be false going forward
                require(disabled, 'disabled: cannot undo disable');
                // if previous checkpoint was disabled, then cannot increase stake going forward
                require(!addElseSub, 'disabled: cannot add stake');
            }

            // ensure block number downcast to uint80 is monotonically increasing (prevent overflow)
            // this should never happen within the lifetime of the universe, but if it does, this prevents a catastrophe
            require(
                prev.blockNumber <= uint80(block.number),
                'block # overflow'
            );

            // calculate blocks elapsed since checkpoint
            uint80 additionalBlocks = (uint80(block.number) - prev.blockNumber);

            // calculate marginal accrued stake weight
            uint192 marginalAccruedStakeWeight = (uint192(additionalBlocks) *
                track.weightAccrualRate *
                prev.totalStaked) / 10**18;

            // calculate new stake weight
            uint192 newStakeWeight = prev.totalStakeWeight +
                marginalAccruedStakeWeight;

            // factor in passive and active rollover decay
            if (_bumpSaleCounter) {
                // get total active rollover amount
                uint192 activeRolloverWeight = trackTotalActiveRollOvers[
                    trackId
                ][prev.numFinishedSales];

                newStakeWeight =
                    // decay active weight
                    (activeRolloverWeight * track.activeRolloverRate) /
                    ROLLOVER_FACTOR_DECIMALS +
                    // decay passive weight
                    ((newStakeWeight - activeRolloverWeight) *
                        track.passiveRolloverRate) /
                    ROLLOVER_FACTOR_DECIMALS;

                // emit
                emit BumpSaleCounter(trackId, prev.numFinishedSales + 1);
            }

            // add a new checkpoint for this track
            // if no blocks elapsed, just update prev checkpoint (so checkpoints can be uniquely identified by block number)
            if (additionalBlocks == 0) {
                prev.totalStaked = addElseSub
                    ? prev.totalStaked + amount
                    : prev.totalStaked - amount;
                prev.totalStakeWeight = prev.disabled
                    ? (
                        prev.totalStakeWeight < newStakeWeight
                            ? prev.totalStakeWeight
                            : newStakeWeight
                    )
                    : newStakeWeight;
                prev.disabled = disabled;
                prev.numFinishedSales = _bumpSaleCounter
                    ? prev.numFinishedSales + 1
                    : prev.numFinishedSales;
            } else {
                trackCheckpoints[trackId][nCheckpoints] = TrackCheckpoint({
                    blockNumber: uint80(block.number),
                    totalStaked: addElseSub
                        ? prev.totalStaked + amount
                        : prev.totalStaked - amount,
                    totalStakeWeight: prev.disabled
                        ? (
                            prev.totalStakeWeight < newStakeWeight
                                ? prev.totalStakeWeight
                                : newStakeWeight
                        )
                        : newStakeWeight,
                    disabled: disabled,
                    numFinishedSales: _bumpSaleCounter
                        ? prev.numFinishedSales + 1
                        : prev.numFinishedSales
                });

                // increase new track's checkpoint count by 1
                trackCheckpointCounts[trackId]++;
            }

            // emit
            if (!prev.disabled && disabled) {
                emit DisableTrack(trackId);
            }
        }

        // emit
        emit AddTrackCheckpoint(trackId, uint80(block.number));
    }

    // stake
    function stake(uint24 trackId, uint104 amount) external nonReentrant {
        // stake amount must be greater than 0
        require(amount > 0, 'amount is 0');

        // get track info
        TrackInfo storage track = tracks[trackId];

        // get latest track checkpoint
        TrackCheckpoint storage checkpoint = trackCheckpoints[trackId][
            trackCheckpointCounts[trackId] - 1
        ];

        // cannot stake into disabled track
        require(!checkpoint.disabled, 'track is disabled');

        // transfer the specified amount of stake token from user to this contract
        track.stakeToken.safeTransferFrom(_msgSender(), address(this), amount);

        // add user checkpoint
        addUserCheckpoint(trackId, amount, true);

        // add track checkpoint
        addTrackCheckpoint(trackId, amount, true, false, false);

        // emit
        emit Stake(trackId, _msgSender(), amount);
    }

    // unstake
    function unstake(uint24 trackId, uint104 amount) external nonReentrant {
        // amount must be greater than 0
        require(amount > 0, 'amount is 0');

        // get track info
        TrackInfo storage track = tracks[trackId];

        // get number of user's checkpoints within this track
        uint32 userCheckpointCount = userCheckpointCounts[trackId][
            _msgSender()
        ];

        // get user's latest checkpoint
        UserCheckpoint storage checkpoint = userCheckpoints[trackId][
            _msgSender()
        ][userCheckpointCount - 1];

        // ensure amount <= user's current stake
        require(amount <= checkpoint.staked, 'amount > staked');

        // add user checkpoint
        addUserCheckpoint(trackId, amount, false);

        // add track checkpoint
        addTrackCheckpoint(trackId, amount, false, false, false);

        // transfer the specified amount of stake token from this contract to user
        track.stakeToken.safeTransfer(_msgSender(), amount);

        // emit
        emit Unstake(trackId, _msgSender(), amount);
    }
}
