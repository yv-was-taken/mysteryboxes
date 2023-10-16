// SPX-License-Identifier: MIT
pragma solidity ^0.8.19;

import { ERC721 } from "@openzeppelin/contracts/token/ERC721.sol";
import { IERC721 } from "@openzeppelin/contracts/interfaces/IERC721.sol";

interface IRandomizer {
    function request(uint256 callbackGasLimit) external returns (uint256);

    function estimateFee(uint256 callbackGasLimit) external returns (uint256);

    function clientDeposit(address client) external payable;

    function clientWithdrawTo(address to, uint256 amount) external;

    function getFeeStats(uint256 request) external view returns (uint256[2] memory);

    function clientBalanceOf(address _client) external view returns (uint256 deposit, uint256 reserved);

    function getRequest(uint256 request) external view returns (bytes32 result, bytes32 dataHash, uint256 ethPaid, uint256 ethRefunded, bytes10[2] memory vrfHashes);
}



interface IERC165 {
    function supportsInterface(bytes4 interfaceID) external view returns (bool);
}

interface IERC721 is IERC165 {
    function balanceOf(address owner) external view returns (uint balance);

    function ownerOf(uint tokenId) external view returns (address owner);

    function safeTransferFrom(address from, address to, uint tokenId) external;

    function safeTransferFrom(
        address from,
        address to,
        uint tokenId,
        bytes calldata data
    ) external;

    function transferFrom(address from, address to, uint tokenId) external;

    function approve(address to, uint tokenId) external;

    function getApproved(uint tokenId) external view returns (address operator);

    function setApprovalForAll(address operator, bool _approved) external;

    function isApprovedForAll(
        address owner,
        address operator
    ) external view returns (bool);
}


interface IERC721Receiver {
    function onERC721Received(
        address operator,
        address from,
        uint tokenId,
        bytes calldata data
    ) external returns (bytes4);
}

//contract outline
// MysteryBox contract is a vault contract that should
// take payment as input in ETH/network native token. 
// and in turn pay out a random token stored inside the vault
// vault tokens can only be deposited by the vault owner
// payments also get sent directly to the owner as well
// MysteryBoxFactory contract is a factory contract that should:
// users that would like their own vault interact with to mint
// their own vault contract
// vault minters can then deposit whatever they want into
// their mystery box...
// (NFTs easiest, maybe redeemable tickets for sets of tokens?)
// and also during mint set their own price for the vault contract
// each MysteryBox contract will allow vault owners to change 
// the price of the box at any time,
// shouldnt need a withdraw/claim fn since vault is denominated
// in the chain native token 
// fun way for users to 'tax loss harvest' their NFTs, could
// make it fun and add some value in there too for users 
// to gamble with, similar product concept to CSGO skins kind of ;p

contract MysteryBoxFactory is ERC721 {

    event Created(address _owner);

    //mint a box 
    //@TODO set a small fee for minting?
    function create(uint price) external {
        MysteryBox Box = new MysteryBox(price, msg.sender);
        emit Created(msg.sender);
    }

}

contract MysteryBox is IERC721Receiver {
    using IERC721 from ERC721;


    //events
    event SpinInitialized(address spinner);
    event SpinCompleted(address spinner, address prize, uint _id);
    event PrizeDeposited(address token, uint id);

    //errors
    error InsufficientSpinFee();
    error InsufficientVRFFee();
    error OutOfTokens();
    error SpinPaymentFailed();
    error InvalidPrizeToken();
    error InvalidAddress();



    //needed for handling VRF refunds
    //mapping request Id to spin payment value to VRF
    mapping(uint256 => uint256) public spinPaymentValue;

    // Map user address to the last callback request
    mapping(address => uint256) public userToLastCallback;

    //gas limit for randomizer callback functions
    uint callbackGasLimit = 100000;


    struct Prize {
        address token,
        uint id,
        bool isAwaitingDistribution

    }

    Prize[] public prizes;


    struct Spin {
        uint price;
        address spinner;
        uint totalPrizes;
        uint prizeIndex;
        uint256 seed;

    }
    //map request id to Spin
    mapping(uint256 => Spin) public spins;




    uint public spinPrice;
    address public owner;
    IRandomizer public immutable randomizer;
    constructor(uint _price, address _owner, address _randomizer) {
        randomizer = _randomizer;
        spinPrice = _price;
        owner = _owner;
    }

    function spin() external payable {
        uint userValue = msg.value;
        uint userVrfFee = msg.value - spinPrice;
        //if spinPrice > msg.value userVrfFee will be zero.
        if(userValue - userVrfFee < spinPrice) revert InsufficientSpinFee();
        //needs to be enough left over to pay VRF
        if (userVrfFee < randomizer.estimateFee(callbackGasLimit) + spinPrice) revert InsufficientVRFFee();
        randomizer.clientDeposit{value: userVrfFee}(address(this));
        uint id = IRandomizer(randomizer).request(callbackGasLimit);
        userValue -= userVrfFee;
        (bool sent,) = owner.call{value: userValue}();
        if(!sent) revert SpinPaymentFailed(); 
        Spin memory _spin = Spin(userValue, msg.sender, prizes.length, 0, 0);

        spins[id] = _spin;
        spinPaymentValue[id] = userVrfFee;
        emit SpinInitialized(msg.sender);





    }

    function randomizerCallback(uint _id, bytes32 _value) external reentrancyGuard {
        if(msg.sender != address(randomizer)) revert OnlyRandomizer();
        Spin memory lastSpin = spins[id];
        uint seed = uint256(_value);
        uint index = seed % lastSpin.totalPrizes;
        lastSpin.prizeIndex = index;
        lastSpin.seed = seed;

        ERC721 prize = prizes[index];
        handlePrizeDistribution(lastSpin.spinner, prize);
        emit SpinCompleted(lastSpin.spinner, prize, id);



        _refund(lastSpin.spinner);
        userToLastCallback[lastSpin.spinner] = _id;



    }


    function handlePrizeDistribution(address spinner, ERC721 prize) private {
        //@TODO implement
        //going to have to do something tricky with NFT deposit function...
        // that allows for this contract to pick up on the token address for the erc721
        // it's receiving, store that inside the prize array, 
        // then call that contract and pass the tokenId to send to the spinner and send the prize
        ERC721(prize.token).safeTransferFrom(address(this), spinner, prize.tokenId);

    }
    


    //@TODO convert deposit "onERC721Received" standard function.
    function deposit(address token, uint id) external onlyOwner {
        if(ERC721(token).ownerOf[id] != msg.sender) error InvalidPrizeToken();
        ERC721(token).safeTransferFrom(msg.sender, address(this), id);
        //approve the randomizer to send token since that will be the one distributing prizes and calling the handlePrizeDistribution() fn.
        ERC721(token).approve(address(randomizer), id);
        //approve vault owner so they can withdraw their prizes later if they want to
        ERC721(token).approve(msg.sender, id);
        Prize _prize = Prize(token, id, false);
        prizes.push(_prize);
        emit PrizeDeposited(address token, uint id);


    }

    //allow vault owner to withdraw deposited prizes
    //@TODO implement.
    function withdraw(address token, uint id) external onlyOwner {
        if(ERC721(token).getApproved(id) != msg.sender) revert InvalidAddress();
        ERC721(token).safeTransferFrom(address(this), msg.sender, id);

        //@TODO remove from prize pool.


    }







    //  @dev Allows a user to request a refund of excess VRF fees.

    function refund() external reentrancyGuard {
        if (!_refund(msg.sender)) revert NoAvailableRefund();
    }


    //  @dev Internal function to process a refund of excess VRF fees to a player.
    //  @param _player The player's address.
    //  @return A boolean indicating if the refund was successful.

    function _refund(address _player) private returns (bool) {
        uint256 refundableId = userToLastCallback[_player];
        if (refundableId > 0) {
            uint256[2] memory feeStats = randomizer.getFeeStats(refundableId);
            if (darePaymentValue[refundableId] > feeStats[0]) {
                // Refund 90% of the excess deposit to the player
                uint256 refundAmount = darePaymentValue[refundableId] - feeStats[0];
                refundAmount = refundAmount * 9/10;
                (uint256 ethDeposit, uint256 ethReserved) = randomizer.clientBalanceOf(address(this));
                if (refundAmount <= ethDeposit - ethReserved) {
                    // Refund the excess deposit to the player
                    randomizer.clientWithdrawTo(_player, refundAmount);
                    emit Refund(_player, refundAmount, refundableId);
                    return true;
                }
            }
        }
        return false;
    }


}
