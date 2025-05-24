// Module: carbon_nft_manager
module rwa_platform::carbon_nft_manager {
    // Sui framework imports
    use sui::table::{Self, Table};
    use sui::display::{Self}; // For Display objects
    use sui::package::{Self, Publisher}; // For Publisher object
    use sui::object::{Self, UID, ID};
    use sui::transfer::{Self, transfer, public_transfer, share_object, public_share_object, freeze_object}; // Explicitly import transfer functions
    use sui::tx_context::{Self, TxContext};
    use sui::event;

    // Standard library imports
    use std::string::{Self, String}; // Assuming UTF8 string from std
    use std::vector;

    /// Represents a unique, verified carbon credit tied to a specific event.
    public struct CarbonCreditNFT has key, store {
        id: UID,
        /// Amount of CO2 equivalent in chosen unit (e.g., kg).
        amount_kg_co2e: u64,
        /// Code representing the activity type (e.g., 1=Cycling, 2=Walking).
        activity_type: u8,
        /// Unique ID from the verification oracle for the specific event.
        verification_id: vector<u8>,
        /// Timestamp (Unix milliseconds) when the NFT was minted.
        issuance_timestamp_ms: u64,
    }

    /// Soulbound Token representing proof of retiring a CarbonCreditNFT.
    public struct RetirementCertificate has key, store {
        id: UID,
        /// ID of the original CarbonCreditNFT that was retired.
        original_nft_id: ID,
        /// Address of the account that retired the NFT.
        retirer_address: address,
        /// Amount from the retired NFT.
        retired_amount_kg_co2e: u64,
        /// Verification ID from the retired NFT.
        original_verification_id: vector<u8>,
        /// Timestamp (Unix milliseconds) when the retirement occurred.
        retirement_timestamp_ms: u64,
    }

    /// One-time witness for claiming the Publisher object.
    public struct CARBON_NFT_MANAGER has drop {}

    /// Capability object granting minting authority. Held by the backend.
    public struct AdminCap has key, store {
        id: UID
    }

    /// Shared object to prevent double-minting based on verification_id.
    public struct VerificationRegistry has key, store {
        id: UID,
        /// Table mapping verification_id (bytes) to true if processed.
        processed_ids: Table<vector<u8>, bool>
    }

    // --- Event Structs ---

    /// Emitted when a new CarbonCreditNFT is minted.
    public struct MintNFTEvent has copy, drop, store {
        nft_id: ID,
        recipient: address,
        amount_kg_co2e: u64,
        verification_id: vector<u8>,
    }

    /// Emitted when a CarbonCreditNFT is retired (burned).
    public struct RetireNFTEvent has copy, drop, store {
        retirer: address,
        nft_id: ID,
        amount_kg_co2e: u64,
        verification_id: vector<u8>,
    }

    public struct CertificateMinted has copy, drop, store {
        certificate_id: ID,
        retirer_address: address,
        retired_amount_kg_co2e: u64,
        original_verification_id: vector<u8>,
        retirement_timestamp_ms: u64,
    }

    // Inside carbon_nft_manager or a related module
    public struct BridgeToErc20Payload has copy, drop, store {
        sui_nft_id: ID,
        amount_kg_co2e: u64,
        activity_type: u8, // Keep if relevant for ERC20 representation
        original_verification_id: vector<u8>,
        sui_owner_address: address, // Original owner on SUI
        evm_recipient_address: vector<u8>, // Target recipient on EVM (bytes for address)
        target_evm_chain_id: u16, // Wormhole Chain ID of the target EVM chain
    }

    // For signaling retirement (if you want to make this cross-chain)
    public struct CrossChainRetirementPayload has copy, drop, store {
        original_sui_nft_id: ID,
        retirer_sui_address: address,
        retired_amount_kg_co2e: u64,
        original_verification_id: vector<u8>,
        retirement_sui_timestamp_ms: u64,
        target_evm_chain_id: u16,
    }

    public struct NFTPentToBridgeEvent has copy, drop, store {
        sui_nft_id: ID,
        target_chain_id: u16,
        evm_recipient_address: vector<u8>,
        amount_kg_co2e: u64,
    }
    // Emit this in `initiate_bridge_nft_to_erc20`

    // --- Getter Functions for CarbonCreditNFT ---

    /// Returns the amount of CO2e in the NFT.
    public fun get_nft_amount(nft: &CarbonCreditNFT): u64 {
        nft.amount_kg_co2e
    }

    /// Returns the activity type code of the NFT.
    public fun get_nft_activity_type(nft: &CarbonCreditNFT): u8 {
        nft.activity_type
    }

    /// Returns the verification ID of the NFT.
    public fun get_nft_verification_id(nft: &CarbonCreditNFT): vector<u8> {
        nft.verification_id
    }

    /// Returned if the amount_kg_co2e provided for minting is zero.
    const EInvalidAmount: u64 = 1;
    /// Returned if trying to mint with a verification_id that has already been used.
    const EVerificationIdAlreadyProcessed: u64 = 2;

    /// Initializes the module: claims Publisher, creates AdminCap, and shares VerificationRegistry.
    /// Called once during module deployment/upgrade.
    fun init(witness: CARBON_NFT_MANAGER, ctx: &mut TxContext) {
        // 1. Claim the Publisher object using the one-time witness
        let publisher = package::claim(witness, ctx);
        transfer::public_transfer(publisher, tx_context::sender(ctx));

        // 2. Create and transfer AdminCap
        let admin_cap = AdminCap { id: object::new(ctx) };
        transfer::public_transfer(admin_cap, tx_context::sender(ctx));

        // 3. Create and share the Verification Registry (for minting)
        let verification_registry = VerificationRegistry {
            id: object::new(ctx),
            processed_ids: table::new<vector<u8>, bool>(ctx)
        };
        transfer::share_object(verification_registry);
    }

    /// Creates and shares the Display object for CarbonCreditNFT.
    /// Must be called once by the package publisher after deployment.
    #[allow(share_owned)] // Suppress warning as Display is newly created here
    public entry fun create_display(publisher: &Publisher, ctx: &mut TxContext) {
         // Create the Display object as mutable.
        let mut display_obj = display::new<CarbonCreditNFT>(publisher, ctx); // Renamed to display_obj to avoid conflict with module

        // Set collection-level metadata.
        let keys = vector[
            string::utf8(b"name"),
            string::utf8(b"description"),
            // string::utf8(b"image_url"), // Example: "https://yourproject.xyz/nft_image/{id}.png"
            // string::utf8(b"project_url") // Example: "https://yourproject.xyz"
        ];
        let values = vector[
            string::utf8(b"Verified Carbon Credit NFT"),
            string::utf8(b"A unique NFT representing verified carbon credits from sustainable transport activities."),
            // string::utf8(b"https://yourproject.xyz/nft_image/{id}.png"),
            // string::utf8(b"https://yourproject.xyz")
        ];
        display::add_multiple(&mut display_obj, keys, values);
        display::update_version(&mut display_obj); // Increment version after changes

        // Share the display object publicly.
        transfer::public_share_object(display_obj);
    }

    /// Mints a new CarbonCreditNFT. Requires AdminCap authorization.
    /// Checks against VerificationRegistry to prevent double minting.
    public entry fun mint_nft(
        _admin_cap: &AdminCap, // Authorization is implicit by requiring this capability
        registry: &mut VerificationRegistry, // Shared registry to record processed IDs
        recipient: address,
        amount_kg_co2e: u64,
        activity_type: u8,
        verification_id: vector<u8>,
        ctx: &mut TxContext
    ) {
        // 1. Validate input
        assert!(amount_kg_co2e > 0, EInvalidAmount);

        // 2. Prevent Double Minting
        assert!(!table::contains(&registry.processed_ids, verification_id), EVerificationIdAlreadyProcessed);
        // Mark this verification ID as processed
        table::add(&mut registry.processed_ids, copy verification_id, true);

        // 3. Create the NFT Object
        let nft = CarbonCreditNFT {
            id: object::new(ctx),
            amount_kg_co2e: amount_kg_co2e,
            activity_type: activity_type,
            verification_id: copy verification_id, // Store a copy in the NFT
            issuance_timestamp_ms: tx_context::epoch_timestamp_ms(ctx),
        };

        // 4. Emit Mint Event
        event::emit(MintNFTEvent {
            nft_id: object::id(&nft), // Get the ID of the new NFT
            recipient: recipient,
            amount_kg_co2e: amount_kg_co2e,
            verification_id: verification_id, // verification_id was copied for table::add and nft.verification_id
        });

        // 5. Transfer NFT to Recipient
        transfer::public_transfer(nft, recipient);
    }

    /// Retires (burns) a specific CarbonCreditNFT and issues a non-transferable
    /// RetirementCertificate SBT to the retirer. Called by the NFT owner.
    public entry fun retire_nft(nft: CarbonCreditNFT, ctx: &mut TxContext) {
        // Object 'nft' is passed by value, consuming it.

        // 1. Extract necessary data before the object is inaccessible
        let CarbonCreditNFT {
            id: nft_uid_struct, // The UID struct, renamed to avoid confusion with object::id function
            amount_kg_co2e,
            activity_type: _, // Activity type not needed for event/cert, ignored
            verification_id, // Keep this for the certificate
            issuance_timestamp_ms: _, // Timestamp not needed for event/cert, ignored
        } = nft; // 'nft' is consumed/destroyed here

        let nft_id_value: ID = *object::uid_as_inner(&nft_uid_struct); // Get an owned copy of the ID
        let retirer = tx_context::sender(ctx);

        // 2. Emit Retirement Event
        event::emit(RetireNFTEvent {
            retirer: retirer,
            nft_id: nft_id_value,
            amount_kg_co2e: amount_kg_co2e,
            verification_id: copy verification_id, // Copy ID for the event
        });

        // 3. Explicitly delete the UID wrapper of the original NFT.
        // The fields were moved out, but the UID itself needs deletion.
        object::delete(nft_uid_struct);

        // ---- Mint the Retirement Certificate SBT ----
        let retirement_timestamp = tx_context::epoch_timestamp_ms(ctx);
        let certificate = RetirementCertificate {
            id: object::new(ctx), // Create a new UID for the certificate
            original_nft_id: nft_id_value,
            retirer_address: retirer,
            retired_amount_kg_co2e: amount_kg_co2e,
            original_verification_id: verification_id, // Consume the original verification_id here
            retirement_timestamp_ms: retirement_timestamp,
        };

        // Emit Certificate Minted Event
        event::emit(CertificateMinted {
            certificate_id: object::id(&certificate),
            retirer_address: retirer,
            retired_amount_kg_co2e: amount_kg_co2e,
            original_verification_id: copy verification_id, // Copy for the event, original consumed by certificate
            retirement_timestamp_ms: retirement_timestamp
        });

        // Transfer the SBT to the retirer
        transfer::transfer(certificate, retirer);
    }

    /// Function the *owner* of a certificate would call to freeze it.
    /// Takes ownership of the certificate object from the sender.
    public entry fun freeze_my_certificate(certificate: RetirementCertificate, _ctx: &mut TxContext) {
        // The transaction sender must own the 'certificate' object being passed in.
        transfer::freeze_object(certificate);
    }

    // (Assuming you have a way to get Wormhole Core Contract Object ID and necessary constants)
    // Placeholder for Wormhole specific addresses and functions
    // define these constants based on Wormhole's SUI deployment
    // const WORMHOLE_CORE_BRIDGE_ADDRESS: address = @0x...; // Actual Wormhole Core Bridge address on SUI
    // const WORMHOLE_PUBLISH_MESSAGE_FUNCTION_NAME: vector<u8> = b"publish_message";

    public entry fun initiate_bridge_nft_to_erc20(
        nft: CarbonCreditNFT, // Consumes the NFT
        evm_recipient_address: vector<u8>, // Recipient on EVM
        target_evm_chain_id: u16,    // Wormhole Chain ID for EVM chain
        wormhole_fee_coin: sui::coin::Coin<sui::sui::SUI>, // For Wormhole message fee if any
        ctx: &mut TxContext
    ) {
        let sender = tx_context::sender(ctx);

        // 1. Extract data from the NFT
        let CarbonCreditNFT {
            id: nft_uid_struct,
            amount_kg_co2e,
            activity_type,
            verification_id,
            issuance_timestamp_ms: _ // Consumed NFT's id
        } = nft;
        let nft_id_value: ID = *object::uid_as_inner(&nft_uid_struct);

        // (Optional) Lock the NFT in a vault instead of burning, if a return path is desired.
        // For this example, we consume it by decomposing.
        object::delete(nft_uid_struct); // Deleting the UID wrapper.

        // 2. Construct the payload
        let payload = BridgeToErc20Payload {
            sui_nft_id: nft_id_value,
            amount_kg_co2e,
            activity_type,
            original_verification_id: verification_id,
            sui_owner_address: sender,
            evm_recipient_address,
            target_evm_chain_id,
        };

        // 3. Serialize the payload (e.g., to BCS bytes)
        let serialized_payload = sui::bcs::to_bytes(&payload);

        // 4. Publish the message to Wormhole
        // This is a simplified representation. You'll need to use the actual
        // Wormhole SDK/module functions available on SUI.
        // Example:
        // wormhole_sui_module::publish_message(
        //     WORMHOLE_CORE_BRIDGE_OBJECT_ID, // The shared object ID of Wormhole bridge
        //     nonce, // A unique nonce for the message
        //     serialized_payload,
        //     consistency_level, // e.g., 1 for finalized
        //     wormhole_fee_coin, // Pass the coin for fees
        //     ctx
        // );
        // For now, we'll just emit an event as a placeholder for the actual Wormhole call
        event::emit(payload); // Placeholder

        // (Handle wormhole_fee_coin if not consumed by publish_message)
        // if necessary, transfer fee coin back or to a treasury.
        transfer::public_transfer(wormhole_fee_coin, sender);
    }

    #[test_only]
    /// Checks if a verification ID exists in the registry. Only callable in tests.
    public fun is_verification_id_processed(registry: &VerificationRegistry, verification_id: vector<u8>): bool {
        table::contains(&registry.processed_ids, verification_id)
    }

    #[test_only]
    /// Creates an AdminCap for testing purposes.
    public fun test_create_admin_cap(ctx: &mut TxContext): AdminCap {
        AdminCap { id: object::new(ctx) }
    }

    #[test_only]
    /// Creates and shares a VerificationRegistry for testing purposes.
    /// Returns the ID of the shared registry.
    public fun test_create_and_share_registry(ctx: &mut TxContext): ID {
        let registry = VerificationRegistry {
            id: object::new(ctx),
            processed_ids: table::new<vector<u8>, bool>(ctx)
        };
        let registry_id = object::id(&registry); // Get ID before sharing
        transfer::public_share_object(registry); // Use public_share_object for shared objects with store
        registry_id
    }
}
