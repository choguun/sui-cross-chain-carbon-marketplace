module rwa_platform::marketplace {
    // Sui framework imports
    use sui::event;
    use sui::coin::{Self, Coin};
    use sui::sui::SUI;
    use sui::table::{Self, Table};
    use sui::object::{Self, UID, ID};
    use sui::transfer::{Self, public_share_object, public_transfer, share_object}; // Explicitly import used transfer functions
    use sui::tx_context::{Self, TxContext};

    // Standard library imports
    use std::vector; // Explicitly import vector for clarity if used directly

    // Import the NFT struct from the other module (already converted to Sui)
    use rwa_platform::carbon_nft_manager::{CarbonCreditNFT};

    // --- Structs ---

    /// Shared object holding the IDs of currently active listings.
    public struct ListingRegistry has key, store {
        id: UID,
        /// Maps active Listing object IDs to the seller's address.
        active_listings: Table<ID, address>,
        /// Stores the IDs of active listings for easy retrieval.
        active_listing_ids: vector<ID>,
    }

    /// Represents an NFT listed for sale on the marketplace.
    /// Holds the NFT object itself, transferring ownership to the Listing.
    public struct Listing has key, store {
        id: UID,
        /// The object ID of the NFT being sold (for event emission and reference).
        nft_id: ID,
        /// The actual NFT object held by the listing.
        nft: CarbonCreditNFT,
        /// Price in MIST (1,000,000,000 MIST = 1 SUI).
        price_mist: u64,
        /// Original seller's address.
        seller: address,
    }

    // --- Events ---

    /// Emitted when an item is listed.
    public struct ListingCreated has copy, drop, store {
        listing_id: ID, // ID of the Listing object
        nft_id: ID,     // ID of the NFT object inside
        seller: address,
        price_mist: u64,
    }

    /// Emitted when an item is purchased.
    public struct ItemSold has copy, drop, store {
        listing_id: ID,
        nft_id: ID,
        seller: address,
        buyer: address,
        price_mist: u64,
    }

    /// Emitted when a listing is cancelled.
    public struct ListingCancelled has copy, drop, store {
        listing_id: ID,
        nft_id: ID,
        seller: address,
    }

    // --- Errors ---
    const EIncorrectPaymentAmount: u64 = 101;
    const ENotSeller: u64 = 102;
    // const ECoinNotSUI: u64 = 103; // Optional, if restricting to SUI (implicit with Coin<SUI>)

    // --- Functions ---

    /// List an NFT for sale. Consumes the NFT object passed by value.
    public entry fun list_item(
        registry: &mut ListingRegistry, // Registry to record the active listing
        nft: CarbonCreditNFT, // NFT object transferred to the function
        price_mist: u64, // Asking price in MIST
        ctx: &mut TxContext
    ) {
        let sender = tx_context::sender(ctx);
        let nft_original_id = object::id(&nft); // Get NFT ID before it's moved

        // Create the Listing object, taking ownership of the NFT
        let listing = Listing {
            id: object::new(ctx),
            nft_id: nft_original_id,
            nft: nft, // NFT is moved into the listing here
            price_mist: price_mist,
            seller: sender,
        };

        let listing_id = object::id(&listing);

        // Add to registry
        table::add(&mut registry.active_listings, listing_id, sender);
        vector::push_back(&mut registry.active_listing_ids, listing_id);

        // Emit event
        event::emit(ListingCreated {
            listing_id: listing_id,
            nft_id: nft_original_id,
            seller: sender,
            price_mist: price_mist,
        });

        // Share the Listing object so buyers can find it
        transfer::public_share_object(listing);
    }

    /// Buy a listed item.
    public entry fun buy_item(
        registry: &mut ListingRegistry, // Registry to remove the listing from
        listing: Listing, // Pass the Listing object by value
        payment: Coin<SUI>, // Payment coin (must be SUI)
        ctx: &mut TxContext
    ) {
        let buyer = tx_context::sender(ctx);
        let listing_obj_id = object::id(&listing); // Get listing ID before consuming

        // Check payment amount
        assert!(coin::value(&payment) == listing.price_mist, EIncorrectPaymentAmount);

        // Destructure the Listing object to take ownership of its fields
        let Listing {
            id: listing_uid, // UID of the listing object itself
            nft_id,          // Original ID of the NFT
            nft,             // The CarbonCreditNFT object
            price_mist,      // Price
            seller,          // Seller address
        } = listing; // 'listing' is consumed here

        // Remove from registry *before* potential transfer failures
        let _removed_seller = table::remove(&mut registry.active_listings, listing_obj_id);
        // Remove listing ID from the vector
        let (found_in_vec, index_in_vec) = vector::index_of(&registry.active_listing_ids, &listing_obj_id);
        if (found_in_vec) {
            let _ = vector::swap_remove(&mut registry.active_listing_ids, index_in_vec);
        }; // Explicitly terminate the if statement

        // Transfer NFT to buyer
        public_transfer(nft, buyer);

        // Transfer payment to seller
        public_transfer(payment, seller);

        // Emit event
        event::emit(ItemSold {
            listing_id: listing_obj_id,
            nft_id: nft_id,
            seller: seller,
            buyer: buyer,
            price_mist: price_mist,
        });

        // Explicitly delete the Listing object's UID
        object::delete(listing_uid);
    }

    /// Cancel a listing and get the NFT back.
    public entry fun cancel_listing(
        registry: &mut ListingRegistry, // Registry to remove the listing from
        listing: Listing, // Pass the Listing object by value
        ctx: &mut TxContext
    ) {
        let sender = tx_context::sender(ctx);
        let listing_obj_id = object::id(&listing); // Get listing ID before consuming

        // Verify sender is the original seller before consuming the listing
        assert!(sender == listing.seller, ENotSeller);

        // Destructure the Listing object
        let Listing {
            id: listing_uid,
            nft_id,
            nft,
            seller,
            price_mist: _, // Price not needed for cancel event/logic, ignored
        } = listing; // 'listing' is consumed here

        // Remove from registry
        let _removed_seller = table::remove(&mut registry.active_listings, listing_obj_id);
        // Remove listing ID from the vector
        let (found_in_vec, index_in_vec) = vector::index_of(&registry.active_listing_ids, &listing_obj_id);
        if (found_in_vec) {
            let _ = vector::swap_remove(&mut registry.active_listing_ids, index_in_vec);
        }; // Explicitly terminate the if statement

        // Transfer NFT back to seller
        public_transfer(nft, seller);

        // Emit event
        event::emit(ListingCancelled {
            listing_id: listing_obj_id,
            nft_id: nft_id,
            seller: seller, // which is sender
        });

         // Explicitly delete the Listing object's UID
        object::delete(listing_uid);
    }

    // --- Initialization Function --- //

    /// Called once during package deployment. Creates and shares the ListingRegistry.
    fun init(ctx: &mut TxContext) {
        let registry = ListingRegistry {
            id: object::new(ctx),
            active_listings: table::new<ID, address>(ctx),
            active_listing_ids: vector::empty<ID>() // Initialize empty vector
        };
        transfer::share_object(registry); // Share the registry so it can be used
    }

    // --- View Function --- //

    /// Returns a copy of the vector containing the object IDs of all currently active listings.
    public fun get_active_listing_ids(registry: &ListingRegistry): vector<ID> {
        // vector<ID> is copyable because ID has copy ability.
        copy registry.active_listing_ids
    }
}
