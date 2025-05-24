// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Interface for the Wormhole Core Contract on EVM
interface IWormhole {
    struct VM {
        uint8 version;
        uint32 timestamp;
        uint32 nonce;
        uint16 emitterChainId;
        bytes32 emitterAddress;
        uint64 sequence;
        uint8 consistencyLevel;
        bytes payload;
        uint32 guardianSetIndex;
        Signature[] signatures;
        bytes32 hash;
    }
    struct Signature {
        bytes32 r;
        bytes32 s;
        uint8 v;
        uint8 guardianIndex;
    }
    function parseAndVerifyVM(bytes calldata encodedVM) external view returns (VM memory vm, bool valid, string memory reason);
}

// Your ERC20 token that will be minted
interface ICarbonCreditERC20 is IERC20 {
    function mint(address to, uint256 amount) external;
}

contract CarbonNFTBridgeReceiver {
    IWormhole public immutable wormhole;
    ICarbonCreditERC20 public immutable carbonERC20; // Address of your ERC20
    uint16 public immutable suiChainId; // Wormhole Chain ID for SUI
    bytes32 public immutable suiEmitterAddress; // Address of your SUI contract in Wormhole bytes32 format

    mapping(uint64 => bool) public processedVAAs; // emitterChainId + sequence => bool

    event TokensMintedFromSuiNFT(
        bytes32 indexed suiNftId, // Use bytes32 for ID from payload
        address indexed evmRecipient,
        uint256 erc20Amount,
        uint64 suiAmountKgCo2e
    );

    constructor(
        address _wormholeAddress,
        address _carbonERC20Address,
        uint16 _suiChainId,
        bytes32 _suiEmitterAddress
    ) {
        wormhole = IWormhole(_wormholeAddress);
        carbonERC20 = ICarbonCreditERC20(_carbonERC20Address);
        suiChainId = _suiChainId;
        suiEmitterAddress = _suiEmitterAddress;
    }

    // Struct to decode the payload from SUI
    struct BridgeToErc20Payload {
        bytes32 sui_nft_id; // Assuming ID can be represented or hashed to bytes32
        uint64 amount_kg_co2e;
        uint8 activity_type;
        bytes original_verification_id; // vector<u8> becomes bytes
        address sui_owner_address;    // SUI address might need special handling/parsing if not directly an EVM address
        address evm_recipient_address; // EVM address
        uint16 target_evm_chain_id; // This should match the current chain's Wormhole ID
    }

    function receiveAndProcessVAA(bytes calldata encodedVAA) external {
        (IWormhole.VM memory vm, bool isValid, string memory reason) =
            wormhole.parseAndVerifyVM(encodedVAA);

        require(isValid, reason);
        require(vm.emitterChainId == suiChainId, "Invalid emitter chain");
        require(vm.emitterAddress == suiEmitterAddress, "Invalid emitter address");
        // Prevent VAA replay
        require(!processedVAAs[vm.sequence], "VAA already processed");
        processedVAAs[vm.sequence] = true;

        // Decode the payload
        // IMPORTANT: BCS deserialization in Solidity is non-trivial.
        // You might need a library or a simpler fixed-offset parsing if BCS is complex.
        // For simplicity, let's assume a direct abi.decode works IF the SUI payload was structured for it.
        // More realistically, you'd pass a simpler, EVM-friendly byte structure or use a BCS decoding library.
        (BridgeToErc20Payload memory payload) = abi.decode(vm.payload, (BridgeToErc20Payload)); // THIS IS A SIMPLIFICATION

        // Logic to determine ERC20 amount, e.g., 1:1 with amount_kg_co2e (ensure decimals match)
        uint256 erc20AmountToMint = payload.amount_kg_co2e * (10**18); // Assuming 18 decimals for ERC20

        carbonERC20.mint(payload.evm_recipient_address, erc20AmountToMint);

        emit TokensMintedFromSuiNFT(
            payload.sui_nft_id,
            payload.evm_recipient_address,
            erc20AmountToMint,
            payload.amount_kg_co2e
        );
    }

    // Function to allow owner to set a new emitter if needed
    // function setEmitter(uint16 chainId, bytes32 address) external onlyOwner {
    //     registeredEmitters[chainId] = address;
    // }
}