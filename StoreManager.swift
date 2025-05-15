
import StoreKit
import FirebaseFunctions
import FirebaseAuth
import FirebaseDatabase
import SwiftUI


class StoreManager: NSObject, ObservableObject, SKProductsRequestDelegate, SKPaymentTransactionObserver {
    @Published var products: [SKProduct] = []
    @Published var currentSubscriptionPlan: SubscriptionPlan = .none
    @Published var isLoading = false
    
    private let productIdentifiers: Set<String> = [
        "com.zthreesolutions.tolerancetracker.room01",
        "com.zthreesolutions.tolerancetracker.room02",
        "com.zthreesolutions.tolerancetracker.room03",
        "com.zthreesolutions.tolerancetracker.room04",
        "com.zthreesolutions.tolerancetracker.room05"
    ]
    private var completion: ((Bool, String?) -> Void)?
    
    override init() {
        super.init()
        SKPaymentQueue.default().add(self)
        requestProducts()
    }
    
    // Maps product IDs to room limits
    func getRoomLimitForProduct(_ productID: String) -> Int {
        switch productID {
        case "com.zthreesolutions.tolerancetracker.room01": return 1
        case "com.zthreesolutions.tolerancetracker.room02": return 2
        case "com.zthreesolutions.tolerancetracker.room03": return 3
        case "com.zthreesolutions.tolerancetracker.room04": return 4
        case "com.zthreesolutions.tolerancetracker.room05": return 5
        default: return 0
        }
    }
    
    // Gets appropriate upgrade product based on current room count
    func getAppropriateProduct(for roomCount: Int) -> SKProduct? {
        guard roomCount > 0 && roomCount <= 5 else { return nil }
        let productID = "com.tolerancetracker.plan\(roomCount)room" + (roomCount > 1 ? "s" : "")
        return products.first { $0.productIdentifier == productID }
    }
    
    func requestProducts() {
        print("Requesting products: \(productIdentifiers)")
        isLoading = true
        
        // Normal StoreKit request
        let request = SKProductsRequest(productIdentifiers: productIdentifiers)
        request.delegate = self
        request.start()
    }
    
    func productsRequest(_ request: SKProductsRequest, didReceive response: SKProductsResponse) {
        DispatchQueue.main.async {
            self.products = response.products.sorted {
                self.getRoomLimitForProduct($0.productIdentifier) <
                    self.getRoomLimitForProduct($1.productIdentifier)
            }
            self.isLoading = false
            print("Received products: \(self.products.map { $0.productIdentifier })")
            if response.products.isEmpty {
                print("No products found. Invalid product IDs: \(response.invalidProductIdentifiers)")
            }
        }
    }
    
    func buyProduct(_ product: SKProduct, completion: @escaping (Bool, String?) -> Void = { _, _ in }) {
        print("Initiating purchase for product: \(product.productIdentifier)")
        self.completion = completion
        self.isLoading = true
        
        // Real purchase flow
        let payment = SKPayment(product: product)
        SKPaymentQueue.default().add(payment)
    }
    
    func paymentQueue(_ queue: SKPaymentQueue, updatedTransactions transactions: [SKPaymentTransaction]) {
        for transaction in transactions {
            switch transaction.transactionState {
            case .purchased, .restored:
                print("Transaction completed: \(transaction.payment.productIdentifier)")
                validateReceipt { success, error in
                    self.isLoading = false
                    self.completion?(success, error)
                    self.completion = nil
                }
                SKPaymentQueue.default().finishTransaction(transaction)
            case .failed:
                print("Transaction failed: \(transaction.error?.localizedDescription ?? "Unknown error")")
                self.isLoading = false
                completion?(false, transaction.error?.localizedDescription)
                SKPaymentQueue.default().finishTransaction(transaction)
            default:
                break
            }
        }
    }
    
    func restorePurchases(completion: @escaping (Bool, String?) -> Void = { _, _ in }) {
        print("Restoring purchases")
        self.completion = completion
        self.isLoading = true
        
        // Real restore flow
        SKPaymentQueue.default().restoreCompletedTransactions()
    }
    
    func manageSubscriptions() {
        print("Opening subscription management")
        if let url = URL(string: "https://apps.apple.com/account/subscriptions") {
            UIApplication.shared.open(url)
        }
    }
    
    private func validateReceipt(completion: @escaping (Bool, String?) -> Void) {
        guard let receiptURL = Bundle.main.appStoreReceiptURL,
              let receiptData = try? Data(contentsOf: receiptURL) else {
            print("No receipt found")
            completion(false, "No receipt found")
            return
        }

        let receiptString = receiptData.base64EncodedString()
        print("Validating receipt with Firebase Functions")
        let functions = Functions.functions()
        
        functions.httpsCallable("validateReceiptTiered").call(["receipt": receiptString]) { result, error in
            if let error = error {
                print("Receipt validation failed: \(error.localizedDescription)")
                completion(false, error.localizedDescription)
                return
            }

            guard let data = result?.data as? [String: Any],
                  let success = data["success"] as? Bool,
                  let planID = data["planID"] as? String,
                  let roomLimit = data["roomLimit"] as? Int else {
                print("Invalid response from server during receipt validation")
                completion(false, "Invalid response from server")
                return
            }

            print("Receipt validation success: \(success), Plan: \(planID), Limit: \(roomLimit)")
            
            // Update local state
            DispatchQueue.main.async {
                self.currentSubscriptionPlan = SubscriptionPlan(productID: planID)
                UserDefaults.standard.set(planID, forKey: "currentSubscriptionPlan")
                
                // Update Firebase Realtime Database
                if let userId = Auth.auth().currentUser?.uid {
                    let database = Database.database().reference()
                    database.child("users").queryOrdered(byChild: "authId").queryEqual(toValue: userId).observeSingleEvent(of: .value) { snapshot in
                        if snapshot.exists(), let userData = snapshot.value as? [String: [String: Any]], let userKey = userData.keys.first {
                            database.child("users").child(userKey).updateChildValues([
                                "subscriptionPlan": planID,
                                "roomLimit": roomLimit
                            ]) { error, _ in
                                if let error = error {
                                    print("Error updating user subscription: \(error)")
                                    completion(false, error.localizedDescription)
                                } else {
                                    print("Successfully updated user subscription to \(planID) with limit \(roomLimit)")
                                    NotificationCenter.default.post(
                                        name: Notification.Name("SubscriptionUpdated"),
                                        object: nil,
                                        userInfo: ["plan": planID, "limit": roomLimit]
                                    )
                                    completion(success, nil)
                                }
                            }
                        } else {
                            print("User not found in database")
                            completion(false, "User not found in database")
                        }
                    }
                } else {
                    print("No authenticated user")
                    completion(false, "No authenticated user")
                }
            }
        }
    }
}

// Define subscription plans
enum SubscriptionPlan: String {
    case none = "none"
    case plan1Room = "com.zthreesolutions.tolerancetracker.room01"
    case plan2Rooms = "com.zthreesolutions.tolerancetracker.room02"
    case plan3Rooms = "com.zthreesolutions.tolerancetracker.room03"
    case plan4Rooms = "com.zthreesolutions.tolerancetracker.room04"
    case plan5Rooms = "com.zthreesolutions.tolerancetracker.room05"
    
    init(productID: String) {
        switch productID {
        case "com.zthreesolutions.tolerancetracker.room01": self = .plan1Room
        case "com.zthreesolutions.tolerancetracker.room02": self = .plan2Rooms
        case "com.zthreesolutions.tolerancetracker.room03": self = .plan3Rooms
        case "com.zthreesolutions.tolerancetracker.room04": self = .plan4Rooms
        case "com.zthreesolutions.tolerancetracker.room05": self = .plan5Rooms
        default: self = .none
        }
    }
    
    var roomLimit: Int {
        switch self {
        case .none: return 0
        case .plan1Room: return 1
        case .plan2Rooms: return 2
        case .plan3Rooms: return 3
        case .plan4Rooms: return 4
        case .plan5Rooms: return 5
        }
    }
    
    var displayName: String {
        switch self {
        case .none: return "No Subscription"
        case .plan1Room: return "1 Room Plan"
        case .plan2Rooms: return "2 Room Plan"
        case .plan3Rooms: return "3 Room Plan"
        case .plan4Rooms: return "4 Room Plan"
        case .plan5Rooms: return "5 Room Plan"
        }
    }
}
// Mock SKProduct for testing in simulator
class MockSKProduct: SKProduct {
    private let _productIdentifier: String
    private let _price: NSDecimalNumber
    private let _priceLocale: Locale
    private let _localizedTitle: String
    private let _localizedDescription: String
    
    init(productIdentifier: String, price: NSDecimalNumber, priceLocale: Locale,
         localizedTitle: String, localizedDescription: String) {
        self._productIdentifier = productIdentifier
        self._price = price
        self._priceLocale = priceLocale
        self._localizedTitle = localizedTitle
        self._localizedDescription = localizedDescription
        super.init()
    }
    
    override var productIdentifier: String { return _productIdentifier }
    override var price: NSDecimalNumber { return _price }
    override var priceLocale: Locale { return _priceLocale }
    override var localizedTitle: String { return _localizedTitle }
    override var localizedDescription: String { return _localizedDescription }
}
