// Module: carbon_nft_manager
module rwa_platform::carbon_nft_manager {
    // Sui framework imports
    use sui::table::{Self, Table};
    use sui::display::{Self}; // For Display objects
    use sui::package::{Self, Publisher}; // For Publisher object
    use sui::object::{new, id, uid_as_inner, delete}; // UID and ID are default aliases
    use sui::transfer::{public_transfer, share_object, public_share_object, transfer, freeze_object}; // Specific imports
    use sui::tx_context::{sender, epoch_timestamp_ms}; // TxContext type is a default alias
    use sui::event;
    use sui::coin::{Self, TreasuryCap, Coin}; // Import Coin and TreasuryCap
    use sui::sui::SUI;

    // Standard library imports
    use std::string; 
    use std::option::{some, none, is_none, fill, is_some, borrow}; 

    // Wormhole and Token Bridge imports
    use wormhole::emitter::{EmitterCap}; 
    use wormhole::publish_message::{publish_message, MessageTicket}; 
    use wormhole::state as WormholeStateModule; // Alias for wormhole::state
    use token_bridge::state as TokenBridgeStateModule; // Alias for token_bridge::state
    // Unused token_bridge module imports removed, calls will be fully qualified or compiler will guide if needed

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

    /// Fungible token representing carbon credits, backed by retired NFTs.
    public struct CarbonCreditToken has store, drop {}

    /// One-time witness for claiming the Publisher object.
    public struct CARBON_NFT_MANAGER has drop {}

    /// Capability object granting administrative authority and holding key resources.
    public struct AdminCap has key, store {
        id: UID,
        /// Wormhole Core Bridge State Object ID
        wormhole_state_id: Option<ID>,
        /// Token Bridge State Object ID
        token_bridge_state_id: Option<ID>,
        /// Emitter capability for sending Wormhole messages from this contract
        emitter_cap: Option<EmitterCap>, // Direct use of EmitterCap
        /// TreasuryCap for minting/burning CarbonCreditToken
        carbon_token_treasury: TreasuryCap<CarbonCreditToken>,
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

    /// Emitted when a CarbonCreditNFT is retired (burned) locally.
    public struct RetireNFTEvent has copy, drop, store {
        retirer: address,
        nft_id: ID,
        amount_kg_co2e: u64,
        verification_id: vector<u8>,
    }

    /// Emitted when a RetirementCertificate SBT is minted.
    public struct CertificateMinted has copy, drop, store {
        certificate_id: ID,
        retirer_address: address,
        retired_amount_kg_co2e: u64,
        original_verification_id: vector<u8>,
        retirement_timestamp_ms: u64,
    }

    /// Payload for bridging the value of a retired NFT to an ERC20 on EVM.
    /// This is the custom payload included in the Wormhole Token Bridge message.
    public struct BridgeToErc20Payload has copy, drop, store {
        sui_nft_id: ID,
        amount_kg_co2e: u64,
        activity_type: u8, // Keep if relevant for ERC20 representation
        original_verification_id: vector<u8>,
        sui_owner_address: address, // Original owner on SUI
        evm_recipient_address: vector<u8>, // Target recipient on EVM (bytes for address)
        target_evm_chain_id: u16, // Wormhole Chain ID of the target EVM chain
    }

    /// Emitted when an NFT is retired for bridging, before the Wormhole message is published.
    public struct NFTBridgingInitiated has copy, drop, store {
        sui_nft_id: ID,
        sui_owner_address: address,
        amount_kg_co2e: u64,
        target_chain_id: u16,
        evm_recipient_address: vector<u8>,
    }

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

    // --- Error Constants ---

    /// Returned if the amount_kg_co2e provided for minting is zero.
    const EInvalidAmount: u64 = 1;
    /// Returned if trying to mint with a verification_id that has already been used.
    const EVerificationIdAlreadyProcessed: u64 = 2;
    /// Returned if the CarbonCreditToken type is not registered with the Token Bridge.
    const ECarbonTokenNotRegistered: u64 = 3;
    /// Returned if the AdminCap is not initialized.
    const EAdminCapNotInitialized: u64 = 5;


    /// Initializes the module: claims Publisher, creates AdminCap, and shares VerificationRegistry.
    /// Called once during module deployment/upgrade.
    /// Requires the Wormhole and Token Bridge State Object IDs to be passed in.
    fun init(
        witness: CARBON_NFT_MANAGER,
        ctx: &mut TxContext
    ) {
        // 1. Claim the Publisher object using the one-time witness
        let publisher = package::claim(witness, ctx);
        public_transfer(publisher, sender(ctx));

        // 2. Create the CarbonCreditToken currency
        let (carbon_token_treasury, carbon_token_metadata) =
            coin::create_currency<CarbonCreditToken>(
                CarbonCreditToken {}, // Witness is an instance of CarbonCreditToken
                0, 
                b"CCT",
                b"Carbon Credit Token",
                b"Fungible token representing verified carbon credits.",
                none(),
                ctx
            );
        public_share_object(carbon_token_metadata);

        // 3. Create AdminCap (without bridge details initially)
        let admin_cap = AdminCap {
            id: new(ctx),
            wormhole_state_id: none(),
            token_bridge_state_id: none(),
            emitter_cap: none(),
            carbon_token_treasury: carbon_token_treasury,
        };
        public_transfer(admin_cap, sender(ctx));

        // 4. Create and share the Verification Registry
        let verification_registry = VerificationRegistry {
            id: new(ctx),
            processed_ids: table::new<vector<u8>, bool>(ctx)
        };
        share_object(verification_registry);
    }

    /// Sets up the bridge-related fields in the AdminCap.
    /// Should be called by the contract admin after initial deployment.
    public entry fun setup_bridge_admin(
        admin_cap: &mut AdminCap,
        wormhole_state_id: ID,
        token_bridge_state_id: ID,
        _wormhole_state_for_emitter: &WormholeStateModule::State, // Use aliased module
        _ctx: &mut TxContext
    ) {
        // Ensure this can only be called once or by an authorized party if needed
        assert!(is_none(&admin_cap.wormhole_state_id), 1001); 
        assert!(is_none(&admin_cap.token_bridge_state_id), 1001);
        assert!(is_none(&admin_cap.emitter_cap), 1001);

        let new_emitter_cap = wormhole::emitter::new(_wormhole_state_for_emitter, _ctx); 

        fill(&mut admin_cap.emitter_cap, new_emitter_cap);
        fill(&mut admin_cap.wormhole_state_id, wormhole_state_id);
        fill(&mut admin_cap.token_bridge_state_id, token_bridge_state_id);
    }

    /// Creates and shares the Display object for CarbonCreditNFT.
    /// Must be called once by the package publisher after deployment.
    #[allow(lint(share_owned))]
    public entry fun create_nft_display(publisher: &Publisher, ctx: &mut TxContext) {
         // Create the Display object as mutable.
        let mut display_obj = display::new<CarbonCreditNFT>(publisher, ctx);

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
        public_share_object(display_obj);
    }

    /// Creates and shares the Display object for RetirementCertificate.
    /// Must be called once by the package publisher after deployment.
    #[allow(lint(share_owned))]
    public entry fun create_certificate_display(publisher: &Publisher, ctx: &mut TxContext) {
        let mut display_obj = display::new<RetirementCertificate>(publisher, ctx);
        let keys = vector[
            string::utf8(b"name"),
            string::utf8(b"description"),
        ];
        let values = vector[
            string::utf8(b"Carbon Credit Retirement Certificate"),
            string::utf8(b"Proof of retirement for a verified carbon credit NFT."),
        ];
        display::add_multiple(&mut display_obj, keys, values);
        display::update_version(&mut display_obj);
        public_share_object(display_obj);
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
            id: new(ctx),
            amount_kg_co2e: amount_kg_co2e,
            activity_type: activity_type,
            verification_id: copy verification_id, // Store a copy in the NFT
            issuance_timestamp_ms: epoch_timestamp_ms(ctx),
        };

        // 4. Emit Mint Event
        event::emit(MintNFTEvent {
            nft_id: id(&nft), // Get the ID of the new NFT
            recipient: recipient,
            amount_kg_co2e: amount_kg_co2e,
            verification_id: verification_id, // verification_id was copied for table::add and nft.verification_id
        });

        // 5. Transfer NFT to Recipient
        public_transfer(nft, recipient);
    }

    /// Retires (burns) a specific CarbonCreditNFT and issues a non-transferable
    /// RetirementCertificate SBT to the retirer. Called by the NFT owner.
    /// This function is for *local* retirement only.
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

        let nft_id_value: ID = *uid_as_inner(&nft_uid_struct); // Get an owned copy of the ID
        let retirer = sender(ctx);

        // 2. Emit Retirement Event
        event::emit(RetireNFTEvent {
            retirer: retirer,
            nft_id: nft_id_value,
            amount_kg_co2e: amount_kg_co2e,
            verification_id: copy verification_id, // Copy ID for the event
        });

        // 3. Explicitly delete the UID wrapper of the original NFT.
        // The fields were moved out, but the UID itself needs deletion.
        delete(nft_uid_struct);

        // ---- Mint the Retirement Certificate SBT ----
        let retirement_timestamp = epoch_timestamp_ms(ctx);
        let certificate = RetirementCertificate {
            id: new(ctx), // Create a new UID for the certificate
            original_nft_id: nft_id_value,
            retirer_address: retirer,
            retired_amount_kg_co2e: amount_kg_co2e,
            original_verification_id: verification_id, // Consume the original verification_id here
            retirement_timestamp_ms: retirement_timestamp,
        };

        // Emit Certificate Minted Event
        event::emit(CertificateMinted {
            certificate_id: id(&certificate),
            retirer_address: retirer,
            retired_amount_kg_co2e: amount_kg_co2e,
            original_verification_id: copy verification_id, // Copy for the event, original consumed by certificate
            retirement_timestamp_ms: retirement_timestamp
        });

        // Transfer the SBT to the retirer
        transfer(certificate, retirer);
    }

    /// Function the *owner* of a certificate would call to freeze it.
    /// Takes ownership of the certificate object from the sender.
    #[allow(lint(custom_state_change))]
    public entry fun freeze_my_certificate(certificate: RetirementCertificate, _ctx: &mut TxContext) {
        // The transaction sender must own the 'certificate' object being passed in.
        freeze_object(certificate);
    }

    /// Initiates the process to bridge the value of a retired CarbonCreditNFT
    /// to a fungible CarbonCreditToken on a target EVM chain via Wormhole.
    /// This function consumes the NFT, mints the equivalent amount of
    /// CarbonCreditToken, and sends it through the Wormhole Token Bridge
    /// with a custom payload containing the NFT's details.
    /// Called by the NFT owner.
    public entry fun retire_and_bridge_nft(
        nft: CarbonCreditNFT, // Consumes the NFT
        admin_cap: &mut AdminCap, // Revert to &mut AdminCap for minting
        wh_state: &mut WormholeStateModule::State, // Use aliased module
        tb_state: &mut TokenBridgeStateModule::State, // Use aliased module
        the_clock: &sui::clock::Clock, 
        evm_recipient_address: vector<u8>, 
        target_evm_chain_id: u16,    
        wormhole_fee_coin: Coin<SUI>, 
        ctx: &mut TxContext
    ) {
        let sender = sender(ctx);

        assert!(is_some(&admin_cap.emitter_cap), EAdminCapNotInitialized);

        // 1. Extract data from the NFT and consume it
        let CarbonCreditNFT {
            id: nft_uid_struct,
            amount_kg_co2e,
            activity_type,
            verification_id,
            issuance_timestamp_ms: _
        } = nft;
        let nft_id_value: ID = *uid_as_inner(&nft_uid_struct);
        delete(nft_uid_struct);

        // 2. Mint CarbonCreditToken
        let minted_balance = coin::mint_balance(&mut admin_cap.carbon_token_treasury, amount_kg_co2e);

        // 3. Get VerifiedAsset info for CarbonCreditToken
        let carbon_token_asset_info = TokenBridgeStateModule::verified_asset<CarbonCreditToken>(tb_state);
        assert!(!token_bridge::token_registry::is_wrapped(&carbon_token_asset_info), ECarbonTokenNotRegistered);

        // 4. Construct custom payload
        let custom_payload = BridgeToErc20Payload {
            sui_nft_id: nft_id_value,
            amount_kg_co2e,
            activity_type,
            original_verification_id: copy verification_id,
            sui_owner_address: sender,
            evm_recipient_address: copy evm_recipient_address,
            target_evm_chain_id,
        };
        let serialized_custom_payload = sui::bcs::to_bytes(&custom_payload);

        // 5. Prepare Wormhole Token Bridge transfer
        assert!(is_some(&admin_cap.emitter_cap), EAdminCapNotInitialized); // Ensure it's Some
        let emitter_cap_ref: &EmitterCap = borrow(&admin_cap.emitter_cap); // Borrow the inner EmitterCap

        let nonce = 0u32; // TODO: Implement robust nonce generation

        let (transfer_ticket, dust_coin) = token_bridge::transfer_tokens_with_payload::prepare_transfer(
            emitter_cap_ref, 
            carbon_token_asset_info,
            coin::from_balance(minted_balance, ctx),
            target_evm_chain_id,
            copy evm_recipient_address, 
            serialized_custom_payload,
            nonce 
        );
        coin::destroy_zero(dust_coin);

        // 6. Publish Wormhole message via Token Bridge
        let wh_message_ticket: MessageTicket = token_bridge::transfer_tokens_with_payload::transfer_tokens_with_payload(
            tb_state,
            transfer_ticket
        );

        // 7. Publish Wormhole message using the core bridge
        publish_message( 
            wh_state, 
            wormhole_fee_coin,
            wh_message_ticket, // Use the typed variable
            the_clock 
        );

        // 8. Emit event
        event::emit(NFTBridgingInitiated {
            sui_nft_id: nft_id_value,
            sui_owner_address: sender,
            amount_kg_co2e,
            target_chain_id: target_evm_chain_id,
            evm_recipient_address,
        });
    }

    #[test_only]
    /// Checks if a verification ID exists in the registry. Only callable in tests.
    public fun is_verification_id_processed(registry: &VerificationRegistry, verification_id: vector<u8>): bool {
        table::contains(&registry.processed_ids, verification_id)
    }

    #[test_only]
    /// Creates an AdminCap for testing purposes.
    public fun test_create_admin_cap(
        wormhole_state_id: ID,
        token_bridge_state_id: ID,
        emitter_cap: EmitterCap, // Direct use of EmitterCap
        carbon_token_treasury: TreasuryCap<CarbonCreditToken>,
        ctx: &mut TxContext
    ): AdminCap {
        AdminCap {
            id: new(ctx),
            wormhole_state_id: some(wormhole_state_id),
            token_bridge_state_id: some(token_bridge_state_id),
            emitter_cap: some(emitter_cap),
            carbon_token_treasury,
        }
    }

    #[test_only]
    /// Creates and shares a VerificationRegistry for testing purposes.
    /// Returns the ID of the shared registry.
    public fun test_create_and_share_registry(ctx: &mut TxContext): ID {
        let registry = VerificationRegistry {
            id: new(ctx),
            processed_ids: table::new<vector<u8>, bool>(ctx)
        };
        let registry_id = id(&registry); // Get ID before sharing
        public_share_object(registry); // Use public_share_object for shared objects with store
        registry_id
    }

    #[test_only]
    /// Helper to create a dummy CarbonCreditToken TreasuryCap for tests
    public fun test_create_carbon_token_treasury(ctx: &mut TxContext): TreasuryCap<CarbonCreditToken> {
        let (treasury, metadata) = coin::create_currency<CarbonCreditToken>(
            CarbonCreditToken {}, 8, b"CCT", b"Carbon Credit Token", b"", none(), ctx
        );
        // In tests, we don't need to share metadata unless explicitly testing that.
        sui::test_utils::destroy(metadata);
        treasury
    }
}