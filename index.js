const functions = require('firebase-functions');
const admin = require('firebase-admin');
const fetch = require('node-fetch');

admin.initializeApp();

exports.validateReceiptTiered = functions.https.onCall(async (data, context) => {
  const receipt = data.receipt;
  if (!receipt) {
    throw new functions.https.HttpsError('invalid-argument', 'Receipt data is required');
  }

  const sharedSecret = 'd7325083fd474c11b46b0ad35beb9524'; // Your shared secret

  try {
    // First try production URL
    let validationResult = await validateReceipt(receipt, sharedSecret, 'https://buy.itunes.apple.com/verifyReceipt');
    
    // If it's a sandbox receipt, try sandbox URL
    if (validationResult.status === 21007) {
      console.log('Received sandbox receipt, switching to sandbox validation');
      validationResult = await validateReceipt(receipt, sharedSecret, 'https://sandbox.itunes.apple.com/verifyReceipt');
    }
    
    // If still unsuccessful, throw error
    if (validationResult.status !== 0) {
      throw new functions.https.HttpsError(
        'invalid-argument', 
        `Receipt validation failed with status: ${validationResult.status}`
      );
    }

    // Determine the current active subscription tier
    let activePlanID = null;
    let roomLimit = 0;
    
    const latestReceiptInfo = validationResult.latest_receipt_info || [];
    const now = Date.now() / 1000; // Current time in seconds
    
    // First collect all active subscriptions
    const activeSubscriptions = latestReceiptInfo.filter(transaction => {
      const expiresDate = parseInt(transaction.expires_date_ms) / 1000;
      return expiresDate > now; // Subscription is still active
    });
    
    // Then find the highest tier subscription (e.g. plan with the most rooms)
    if (activeSubscriptions.length > 0) {
      // Define a mapping for product IDs to room limits
      const planLimits = {
        'com.zthreesolutions.tolerancetracker.room01': 1,
        'com.zthreesolutions.tolerancetracker.room02': 2,
        'com.zthreesolutions.tolerancetracker.room03': 3,
        'com.zthreesolutions.tolerancetracker.room04': 4,
        'com.zthreesolutions.tolerancetracker.room05': 5
      };
      
      // Find subscription with highest room limit
      let highestLimitPlan = null;
      let highestLimit = 0;
      
      for (const subscription of activeSubscriptions) {
        const productId = subscription.product_id;
        const limit = planLimits[productId] || 0;
        
        if (limit > highestLimit) {
          highestLimit = limit;
          highestLimitPlan = productId;
        }
      }
      
      activePlanID = highestLimitPlan;
      roomLimit = highestLimit;
    }

    // Update user's subscription info in Firebase
    const userId = context.auth.uid;
    await admin.database().ref(`users/${userId}`).update({
      subscriptionPlan: activePlanID || null,
      roomLimit: roomLimit
    });

    return { 
      success: true,
      planID: activePlanID || 'none',
      roomLimit: roomLimit
    };
  } catch (error) {
    console.error('Receipt validation error:', error);
    throw new functions.https.HttpsError('internal', `Receipt validation failed: ${error.message}`);
  }
});

// Helper function to validate receipt with a specific URL
async function validateReceipt(receipt, sharedSecret, url) {
  const response = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      'receipt-data': receipt,
      'password': sharedSecret,
      'exclude-old-transactions': true
    })
  });
  
  return await response.json();
}