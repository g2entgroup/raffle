//SPDX-License-Identifier: MIT
pragma solidity 0.7.4;
pragma experimental ABIEncoderV2;

// import "hardhat/console.sol";

import "./interfaces/IERC1155.sol";
import "./chainlink/LinkTokenInterface.sol";

struct AppStorage {
    Raffle[] raffles;
    // Nonces for each VRF key from which randomness has been requested.
    // Must stay in sync with VRFCoordinator[_keyHash][this]
    // keyHash => nonce
    mapping(bytes32 => uint256) nonces;
    mapping(bytes32 => uint256) requestIdToRaffleId;
    bytes32 keyHash;
    uint256 fee;
    address contractOwner;
}

struct Raffle {
    // stakeAddress => (stakeId => index + 1)
    mapping(address => mapping(uint256 => uint256)) raffleItemIndexes;
    RaffleItem[] raffleItems;
    // raffleItemIndex => RafflePrize[]
    mapping(uint256 => RaffleItemPrize[]) raffleItemPrizes;
    mapping(address => UserStake[]) userStakes;
    mapping(address => bool) prizeClaimed;
    address[] stakers;
    uint256 randomNumber;
    uint256 raffleEnd;
}

struct UserStake {
    uint24 raffleItemIndex;
    uint112 rangeStart;
    uint112 rangeEnd;
}

struct RaffleItemPrize {
    address prizeAddress;
    uint96 prizeValue;
    uint256 prizeId;
}

struct RaffleItemPrizeIO {
    address prizeAddress;
    uint256 prizeId;
    uint256 prizeValue;
}

struct RaffleItem {
    address stakeAddress;
    uint256 stakeId;
    uint256 stakeTotal;
    RaffleItemPrize[] raffleItemPrizes;
}

struct RaffleItemIO {
    address stakeAddress;
    uint256 stakeId;
    RaffleItemPrizeIO[] raffleItemPrizes;
}

struct RaffleIO {
    uint256 raffleId;
    uint256 raffleEnd;
}

struct StakeStatsIO {
    address stakeAddress;
    uint256 stakeId;
    uint256 numberOfStakers;
    uint256 stakeTotal;
}

struct StakerStatsIO {
    address stakeAddress;
    uint256 stakeId;
    uint256 stakeValue;
}

struct StakeItemIO {
    address stakeAddress;
    uint256 stakeId;
    uint256 stakeValue;
}

struct StakeWinnerIO {
    address staker;
    bool claimed;
    uint256 userStakeIndex;
    uint256 raffleItemIndex;
    uint256 raffleItemPrizeIndex;
    uint256[] prizeValues;
    uint256 prizeIndex;
}

struct StakeWinIO {
    uint256 userStakeIndex;
    uint256 raffleItemPrizeIndex;
    uint256[] prizeValues;
}

contract RafflesContract {
    AppStorage internal s;
    // Immutable values are prefixed with im_ to easily identify them in code
    LinkTokenInterface internal immutable im_LINK;
    address internal immutable im_vrfCoordinator;
    bytes32 internal immutable im_keyHash;

    bytes4 internal constant ERC1155_ACCEPTED = 0xf23a6e61; // Return value from `onERC1155Received` call if a contract accepts receipt (i.e `bytes4(keccak256("onERC1155Received(address,address,uint256,uint256,bytes)"))`).
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event RaffleStarted(uint256 indexed raffleId, uint256 raffleEnd, RaffleItemIO[] raffleItems);
    event RaffleStaker(uint256 indexed raffleId, address staker, StakeItemIO[] stakeItems);
    event RaffleRandomNumber(uint256 indexed raffleId, uint256 randomNumber);
    event RaffleClaimPrize(uint256 indexed raffleId, address staker, address prizeAddress, uint256 prizeId, uint256 prizeValue);

    constructor(
        address _contractOwner,
        address _vrfCoordinator,
        address _link,
        bytes32 _keyHash
    ) {
        s.contractOwner = _contractOwner;
        im_vrfCoordinator = _vrfCoordinator;
        im_LINK = LinkTokenInterface(_link);
        im_keyHash = _keyHash; //0x6c3699283bda56ad74f6b855546325b68d482e983852a7a82979cc4807b641f4; // Ropsten details
        s.fee = 10**18;
    }

    // VRF Functionality ////////////////////////////////////////////////////////////////
    function nonces(bytes32 _keyHash) external view returns (uint256 nonce_) {
        nonce_ = s.nonces[_keyHash];
    }

    /**
     * @notice requestRandomness initiates a request for VRF output given _seed
     *
     * @dev See "SECURITY CONSIDERATIONS" above for more information on _seed.
     *
     * @dev The fulfillRandomness method receives the output, once it's provided
     * @dev by the Oracle, and verified by the vrfCoordinator.
     *
     * @dev The _keyHash must already be registered with the VRFCoordinator, and
     * @dev the _fee must exceed the fee specified during registration of the
     * @dev _keyHash.
     *
     * @param _keyHash ID of public key against which randomness is generated
     * @param _fee The amount of LINK to send with the request
     * @param _seed seed mixed into the input of the VRF
     *
     * @return requestId unique ID for this request
     *
     * @dev The returned requestId can be used to distinguish responses to *
     * @dev concurrent requests. It is passed as the first argument to
     * @dev fulfillRandomness.
     */
    function requestRandomness(
        bytes32 _keyHash,
        uint256 _fee,
        uint256 _seed
    ) public returns (bytes32 requestId) {
        im_LINK.transferAndCall(im_vrfCoordinator, _fee, abi.encode(_keyHash, _seed));
        // This is the seed passed to VRFCoordinator. The oracle will mix this with
        // the hash of the block containing this request to obtain the seed/input
        // which is finally passed to the VRF cryptographic machinery.
        uint256 vRFSeed = makeVRFInputSeed(_keyHash, _seed, address(this), s.nonces[_keyHash]);
        // nonces[_keyHash] must stay in sync with
        // VRFCoordinator.nonces[_keyHash][this], which was incremented by the above
        // successful LINK.transferAndCall (in VRFCoordinator.randomnessRequest).
        // This provides protection against the user repeating their input
        // seed, which would result in a predictable/duplicate output.
        s.nonces[_keyHash]++;
        return makeRequestId(_keyHash, vRFSeed);
    }

    /**
     * @notice returns the seed which is actually input to the VRF coordinator
     *
     * @dev To prevent repetition of VRF output due to repetition of the
     * @dev user-supplied seed, that seed is combined in a hash with the
     * @dev user-specific nonce, and the address of the consuming contract. The
     * @dev risk of repetition is mostly mitigated by inclusion of a blockhash in
     * @dev the final seed, but the nonce does protect against repetition in
     * @dev requests which are included in a single block.
     *
     * @param _userSeed VRF seed input provided by user
     * @param _requester Address of the requesting contract
     * @param _nonce User-specific nonce at the time of the request
     */
    function makeVRFInputSeed(
        bytes32 _keyHash,
        uint256 _userSeed,
        address _requester,
        uint256 _nonce
    ) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(_keyHash, _userSeed, _requester, _nonce)));
    }

    /**
     * @notice Returns the id for this request
     * @param _keyHash The serviceAgreement ID to be used for this request
     * @param _vRFInputSeed The seed to be passed directly to the VRF
     * @return The id for this request
     *
     * @dev Note that _vRFInputSeed is not the seed passed by the consuming
     * @dev contract, but the one generated by makeVRFInputSeed
     */
    function makeRequestId(bytes32 _keyHash, uint256 _vRFInputSeed) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(_keyHash, _vRFInputSeed));
    }

    function drawRandomNumber(uint256 _raffleId) external {
        require(_raffleId < s.raffles.length, "Raffle: Raffle does not exist");
        Raffle storage raffle = s.raffles[_raffleId];
        require(raffle.raffleEnd < block.timestamp, "Raffle: Raffle time has not expired");
        require(raffle.randomNumber == 0, "Raffle: Random number already generated");
        uint256 randomNumber = uint256(keccak256(abi.encodePacked(block.number)));
        raffle.randomNumber = randomNumber;
        emit RaffleRandomNumber(_raffleId, randomNumber);
    }

    function drawRandomNumber(uint256 _raffleId, uint256 _userProvidedSeed) external {
        require(_raffleId < s.raffles.length, "Raffle: Raffle does not exist");
        Raffle storage raffle = s.raffles[_raffleId];
        require(raffle.raffleEnd < block.timestamp, "Raffle: Raffle time has not expired");
        require(raffle.randomNumber == 0, "Raffle: Random number already generated");
        // Use Chainlink VRF to generate random number
        require(im_LINK.balanceOf(address(this)) > s.fee, "Not enough LINK - fill contract with faucet");
        uint256 seed = uint256(keccak256(abi.encode(_userProvidedSeed, blockhash(block.number)))); // Hash user seed and blockhash
        bytes32 requestId = requestRandomness(s.keyHash, s.fee, seed);
        s.requestIdToRaffleId[requestId] = _raffleId;
    }

    // rawFulfillRandomness is called by VRFCoordinator when it receives a valid VRFproof.
    /**
     * @notice Callback function used by VRF Coordinator
     * @dev Important! Add a modifier to only allow this function to be called by the VRFCoordinator
     * @dev This is where you do something with randomness!
     * @dev The VRF Coordinator will only send this function verified responses.
     * @dev The VRF Coordinator will not pass randomness that could not be verified.
     */
    function rawFulfillRandomness(bytes32 requestId, uint256 randomness) external {
        require(msg.sender == im_vrfCoordinator, "Only VRFCoordinator can fulfill");
        uint256 raffleId = s.requestIdToRaffleId[requestId];
        s.raffles[raffleId].randomNumber = randomness;
        emit RaffleRandomNumber(raffleId, randomness);
    }

    /////////////////////////////////////////////////////////////////////////////////////

    function owner() external view returns (address) {
        return s.contractOwner;
    }

    function transferOwnership(address _newContractOwner) external {
        address previousOwner = s.contractOwner;
        require(msg.sender == previousOwner, "Raffle: Must be contract owner");
        s.contractOwner = _newContractOwner;
        emit OwnershipTransferred(previousOwner, _newContractOwner);
    }

    function startRaffle(uint256 _raffleEnd, RaffleItemIO[] calldata _raffleItems) external {
        require(msg.sender == s.contractOwner, "Raffle: Must be contract owner");
        require(_raffleEnd > block.timestamp + 3600, "Raffle: _raffleEnd must be greater than 1 hour");
        require(_raffleItems.length > 0, "Raffle: No raffle items");
        uint256 raffleId = s.raffles.length;
        emit RaffleStarted(raffleId, _raffleEnd, _raffleItems);
        Raffle storage raffle = s.raffles.push();
        raffle.raffleEnd = uint256(_raffleEnd);
        for (uint256 i; i < _raffleItems.length; i++) {
            RaffleItemIO calldata raffleItemIO = _raffleItems[i];
            require(raffleItemIO.raffleItemPrizes.length > 0, "Raffle: No prizes");
            require(
                raffle.raffleItemIndexes[raffleItemIO.stakeAddress][raffleItemIO.stakeId] == 0,
                "Raffle: Raffle item already using stakeAddress and stakeId"
            );
            RaffleItem storage raffleItem = raffle.raffleItems.push();
            raffle.raffleItemIndexes[raffleItemIO.stakeAddress][raffleItemIO.stakeId] = raffle.raffleItems.length;
            raffleItem.stakeAddress = raffleItemIO.stakeAddress;
            raffleItem.stakeId = raffleItemIO.stakeId;
            for (uint256 j; j < raffleItemIO.raffleItemPrizes.length; j++) {
                RaffleItemPrizeIO memory raffleItemPrizeIO = raffleItemIO.raffleItemPrizes[j];
                raffleItem.raffleItemPrizes.push(
                    RaffleItemPrize(raffleItemPrizeIO.prizeAddress, uint96(raffleItemPrizeIO.prizeValue), raffleItemPrizeIO.prizeId)
                );
                IERC1155(raffleItemPrizeIO.prizeAddress).safeTransferFrom(
                    msg.sender,
                    address(this),
                    raffleItemPrizeIO.prizeId,
                    raffleItemPrizeIO.prizeValue,
                    abi.encode(raffleId)
                );
            }
        }
    }

    /**
        @notice Handle the receipt of a single ERC1155 token type.
        @dev An ERC1155-compliant smart contract MUST call this function on the token recipient contract, at the end of a `safeTransferFrom` after the balance has been updated.        
        This function MUST return `bytes4(keccak256("onERC1155Received(address,address,uint256,uint256,bytes)"))` (i.e. 0xf23a6e61) if it accepts the transfer.
        This function MUST revert if it rejects the transfer.
        Return of any other value than the prescribed keccak256 generated value MUST result in the transaction being reverted by the caller.
        @param _operator  The address which initiated the transfer (i.e. msg.sender)
        @param _from      The address which previously owned the token
        @param _id        The ID of the token being transferred
        @param _value     The amount of tokens being transferred
        @param _data      Additional data with no specified format
        @return           `bytes4(keccak256("onERC1155Received(address,address,uint256,uint256,bytes)"))`
    */
    function onERC1155Received(
        address _operator,
        address _from,
        uint256 _id,
        uint256 _value,
        bytes calldata _data
    ) external view returns (bytes4) {
        _operator; // silence not used warning
        _from; // silence not used warning
        _id; // silence not used warning
        _value; // silence not used warning
        require(_data.length == 32, "Raffle: Incorrect data sent on transfer");
        uint256 raffleId = abi.decode(_data, (uint256));
        require(raffleId < s.raffles.length, "Raffle: Raffle does not exist");
        Raffle storage raffle = s.raffles[raffleId];
        uint256 raffleEnd = raffle.raffleEnd;
        require(raffleEnd > block.timestamp, "Raffle: Can't accept transfer for expired raffle");
        return ERC1155_ACCEPTED;
    }

    function openRaffles() external view returns (RaffleIO[] memory openRaffles_) {
        openRaffles_ = new RaffleIO[](s.raffles.length);
        uint256 numOpen;
        for (uint256 i; i < s.raffles.length; i++) {
            uint256 raffleEnd = s.raffles[i].raffleEnd;
            if (raffleEnd > block.timestamp) {
                openRaffles_[numOpen].raffleId = i;
                openRaffles_[numOpen].raffleEnd = raffleEnd;
                numOpen++;
            }
        }
        assembly {
            mstore(openRaffles_, numOpen)
        }
    }

    function getRaffles() external view returns (RaffleIO[] memory raffles_) {
        raffles_ = new RaffleIO[](s.raffles.length);
        for (uint256 i; i < s.raffles.length; i++) {
            raffles_[i].raffleId = i;
            raffles_[i].raffleEnd = s.raffles[i].raffleEnd;
        }
    }

    function raffleSupply() external view returns (uint256 raffleSupply_) {
        raffleSupply_ = s.raffles.length;
    }

    function raffleInfo(uint256 _raffleId)
        external
        view
        returns (
            uint256 raffleEnd_,
            RaffleItemIO[] memory raffleItems_,
            bool numberChosen_
        )
    {
        require(_raffleId < s.raffles.length, "Raffle: Raffle does not exist");
        Raffle storage raffle = s.raffles[_raffleId];
        raffleEnd_ = raffle.raffleEnd;

        if (raffle.randomNumber == 0) {
            numberChosen_ = false;
        } else {
            numberChosen_ = true;
        }

        raffleItems_ = new RaffleItemIO[](raffle.raffleItems.length);
        for (uint256 i; i < raffle.raffleItems.length; i++) {
            RaffleItem storage raffleItem = raffle.raffleItems[i];
            raffleItems_[i].stakeAddress = raffleItem.stakeAddress;
            raffleItems_[i].stakeId = raffleItem.stakeId;
            raffleItems_[i].raffleItemPrizes = new RaffleItemPrizeIO[](raffleItem.raffleItemPrizes.length);
            for (uint256 j; j < raffleItem.raffleItemPrizes.length; j++) {
                RaffleItemPrize storage raffleItemPrize = raffleItem.raffleItemPrizes[j];
                raffleItems_[i].raffleItemPrizes[j].prizeAddress = raffleItemPrize.prizeAddress;
                raffleItems_[i].raffleItemPrizes[j].prizeId = raffleItemPrize.prizeId;
                raffleItems_[i].raffleItemPrizes[j].prizeValue = raffleItemPrize.prizeValue;
            }
        }
    }

    function stakerStats(uint256 _raffleId, address _staker) external view returns (StakerStatsIO[] memory stakerStats_) {
        require(_raffleId < s.raffles.length, "Raffle: Raffle does not exist");
        Raffle storage raffle = s.raffles[_raffleId];
        stakerStats_ = new StakerStatsIO[](raffle.userStakes[_staker].length);
        for (uint256 i; i < raffle.userStakes[_staker].length; i++) {
            UserStake memory userStake = raffle.userStakes[_staker][i];
            RaffleItem storage raffleItem = raffle.raffleItems[userStake.raffleItemIndex];
            stakerStats_[i].stakeAddress = raffleItem.stakeAddress;
            stakerStats_[i].stakeId = raffleItem.stakeId;
            stakerStats_[i].stakeValue = userStake.rangeEnd - userStake.rangeStart;
        }
    }

    function stakeStats(uint256 _raffleId) external view returns (StakeStatsIO[] memory stakerStats_) {
        require(_raffleId < s.raffles.length, "Raffle: Raffle does not exist");
        Raffle storage raffle = s.raffles[_raffleId];
        stakerStats_ = new StakeStatsIO[](raffle.raffleItems.length);
        for (uint256 i; i < raffle.raffleItems.length; i++) {
            RaffleItem storage raffleItem = raffle.raffleItems[i];
            stakerStats_[i].stakeAddress = raffleItem.stakeAddress;
            stakerStats_[i].stakeId = raffleItem.stakeId;
            stakerStats_[i].stakeTotal = raffleItem.stakeTotal;
            uint256 raffleItemIndex = raffle.raffleItemIndexes[stakerStats_[i].stakeAddress][stakerStats_[i].stakeId] - 1;
            for (uint256 j; j < raffle.stakers.length; j++) {
                address staker = raffle.stakers[j];
                for (uint256 k; k < raffle.userStakes[staker].length; k++) {
                    if (raffleItemIndex == raffle.userStakes[staker][k].raffleItemIndex) {
                        stakerStats_[i].numberOfStakers++;
                        break;
                    }
                }
            }
        }
    }

    function stake(uint256 _raffleId, StakeItemIO[] calldata _stakeItems) external {
        require(_raffleId < s.raffles.length, "Raffle: Raffle does not exist");
        require(_stakeItems.length > 0, "Raffle: Nothing staked");
        Raffle storage raffle = s.raffles[_raffleId];
        require(raffle.raffleEnd > block.timestamp, "Raffle: Raffle time has expired");
        emit RaffleStaker(_raffleId, msg.sender, _stakeItems);
        if (raffle.userStakes[msg.sender].length == 0) {
            raffle.stakers.push(msg.sender);
        }
        for (uint256 i; i < _stakeItems.length; i++) {
            StakeItemIO calldata stakeItem = _stakeItems[i];
            require(stakeItem.stakeValue > 0, "Raffle: Stake value cannot be zero");
            uint256 raffleItemIndex = raffle.raffleItemIndexes[stakeItem.stakeAddress][stakeItem.stakeId];
            require(raffleItemIndex > 0, "Raffle: Stake item doesn't exist for this raffle");
            raffleItemIndex--;
            RaffleItem storage raffleItem = raffle.raffleItems[raffleItemIndex];
            uint256 stakeTotal = raffleItem.stakeTotal;
            raffle.userStakes[msg.sender].push(UserStake(uint24(raffleItemIndex), uint112(stakeTotal), uint112(stakeTotal + stakeItem.stakeValue)));
            raffleItem.stakeTotal = stakeTotal + stakeItem.stakeValue;
            IERC1155(stakeItem.stakeAddress).safeTransferFrom(
                msg.sender,
                address(this),
                stakeItem.stakeId,
                stakeItem.stakeValue,
                abi.encode(_raffleId)
            );
        }
    }

    function winners(uint256 _raffleId) external view returns (StakeWinnerIO[] memory winners_) {
        require(_raffleId < s.raffles.length, "Raffle: Raffle does not exist");
        Raffle storage raffle = s.raffles[_raffleId];
        winners_ = winners(_raffleId, raffle.stakers);
    }

    function winners(uint256 _raffleId, address[] memory _stakers) public view returns (StakeWinnerIO[] memory winners_) {
        require(_raffleId < s.raffles.length, "Raffle: Raffle does not exist");
        Raffle storage raffle = s.raffles[_raffleId];
        uint256 randomNumber = raffle.randomNumber;
        require(randomNumber > 0, "Raffle: Random number not generated yet");
        {
            uint256 numRafflePrizes;
            for (uint256 i; i < raffle.raffleItems.length; i++) {
                RaffleItemPrize[] storage raffleItemPrizes = raffle.raffleItems[i].raffleItemPrizes;
                for (uint256 j; j < raffleItemPrizes.length; j++) {
                    numRafflePrizes += raffleItemPrizes[j].prizeValue;
                }
            }
            winners_ = new StakeWinnerIO[](numRafflePrizes);
        }
        uint256 winnersNum;
        for (uint256 h; h < _stakers.length; h++) {
            address staker = _stakers[h];
            for (uint256 i; i < raffle.userStakes[staker].length; i++) {
                UserStake storage userStake = raffle.userStakes[staker][i];
                uint256 stakeTotal = raffle.raffleItems[userStake.raffleItemIndex].stakeTotal;
                RaffleItemPrize[] storage raffleItemPrizes = raffle.raffleItems[userStake.raffleItemIndex].raffleItemPrizes;
                for (uint256 j; j < raffleItemPrizes.length; j++) {
                    uint256 winnings;
                    address prizeAddress = raffleItemPrizes[j].prizeAddress;
                    uint256 prizeId = raffleItemPrizes[j].prizeId;
                    uint256[] memory prizeValues = new uint256[](raffleItemPrizes[j].prizeValue);
                    for (uint256 k; k < raffleItemPrizes[j].prizeValue; k++) {
                        uint256 winningNumber = uint256(keccak256(abi.encodePacked(randomNumber, prizeAddress, prizeId, k))) % stakeTotal;
                        if (winningNumber >= userStake.rangeStart && winningNumber < userStake.rangeEnd) {
                            prizeValues[winnings] = k;
                            winnings++;
                        }
                    }
                    if (winnings > 0) {
                        assembly {
                            mstore(prizeValues, winnings)
                        }
                        winners_[winnersNum] = StakeWinnerIO(staker, raffle.prizeClaimed[msg.sender], i, userStake.raffleItemIndex, j, prizeValues, prizeId);
                        winnersNum++;
                    }
                }
            }
        }
        assembly {
            mstore(winners_, winnersNum)
        }
    }

    function claimPrize(uint256 _raffleId, StakeWinIO[] calldata _wins) external {
        require(_raffleId < s.raffles.length, "Raffle: Raffle does not exist");
        Raffle storage raffle = s.raffles[_raffleId];
        require(raffle.randomNumber > 0, "Raffle: Random number not generated yet");
        require(raffle.prizeClaimed[msg.sender] == false, "Raffle: Any prizes for account have already been claimed");
        raffle.prizeClaimed[msg.sender] = true;
        UserStake[] storage userStakes = raffle.userStakes[msg.sender];
        uint256 userStakesLength = userStakes.length;
        for (uint256 i; i < _wins.length; i++) {
            StakeWinIO calldata win = _wins[i];
            require(win.userStakeIndex < userStakesLength, "Raffle: User stake does not exist");
            UserStake memory userStake = userStakes[win.userStakeIndex];
            uint256 stakeTotal = raffle.raffleItems[userStake.raffleItemIndex].stakeTotal;
            RaffleItemPrize[] storage raffleItemPrizes = raffle.raffleItems[userStake.raffleItemIndex].raffleItemPrizes;
            require(raffleItemPrizes.length > win.raffleItemPrizeIndex, "Raffle: Raffle prize type does not exist");
            RaffleItemPrize memory raffleItemPrize = raffleItemPrizes[win.raffleItemPrizeIndex];
            uint256 lastPrizeValue;
            for (uint256 j; j < win.prizeValues.length; j++) {
                uint256 prizeValue = win.prizeValues[j];
                require(prizeValue > lastPrizeValue || j == 0, "Raffle: Prize value not greater than last prize value");
                lastPrizeValue = prizeValue;
                require(prizeValue < raffleItemPrize.prizeValue, "Raffle: prizeValue does not exist");
                uint256 winningNumber = uint256(
                    keccak256(abi.encodePacked(raffle.randomNumber, raffleItemPrize.prizeAddress, raffleItemPrize.prizeId, prizeValue))
                ) % stakeTotal;
                require(winningNumber >= userStake.rangeStart && winningNumber < userStake.rangeEnd, "Raffle: Did not win prize");
            }
            emit RaffleClaimPrize(_raffleId, msg.sender, raffleItemPrize.prizeAddress, raffleItemPrize.prizeId, win.prizeValues.length);
            IERC1155(raffleItemPrize.prizeAddress).safeTransferFrom(address(this), msg.sender, raffleItemPrize.prizeId, win.prizeValues.length, "");
        }
    }
}
