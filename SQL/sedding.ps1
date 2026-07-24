$ErrorActionPreference = "Stop"

# SET YOUR VALUES HERE

$SqlServer          = "SQL-DATABASE-SERVER-URL"
$SqlDatabase        = "SQL-DATABASE-NAME"
$OpenAiEndpoint     = "MICROSOFT-FOUNDRY-OPEN-AI-ENDPOINT"
$OpenAiDeployment   = "text-embedding-3-small"
$OpenAiKey          = "<MICROSOFT-FOUNDRY-Open-Ai-Key>"
$EmbeddingDimensions = 1536      # use 3072 if your deployment is text-embedding-3-large


Write-Output "Checking for SqlServer module..."
if (-not (Get-Module -ListAvailable -Name SqlServer)) {
    Install-Module -Name SqlServer -Force -Scope CurrentUser -AllowClobber
}

Write-Output "Getting Entra ID access token for this session..."
Write-Output "(If this fails, run Connect-AzAccount first to sign in.)"
$AccessToken = (Get-AzAccessToken -ResourceUrl "https://database.windows.net/").Token

function Invoke-Sql {
    param([string]$Query)
    Invoke-Sqlcmd -ServerInstance $SqlServer -Database $SqlDatabase `
        -AccessToken $AccessToken -Query $Query -QueryTimeout 120
}

Write-Output "Step 1: Master key + Azure OpenAI credential..."
Invoke-Sql -Query @"
IF NOT EXISTS (SELECT 1 FROM sys.symmetric_keys WHERE name = '##MS_DatabaseMasterKey##')
BEGIN
    CREATE MASTER KEY ENCRYPTION BY PASSWORD = '$(New-Guid)Mk!1';
END
"@

# IMPORTANT: the credential NAME must be the base URL (protocol + FQDN + trailing slash,
# no query string) of the endpoint you're calling. CREATE EXTERNAL MODEL matches the
# credential to the endpoint by comparing this name against the LOCATION URL -- an
# arbitrary name like 'AzureOpenAICredential' will NOT work and causes error 31630.
Invoke-Sql -Query @"
IF EXISTS (SELECT 1 FROM sys.database_scoped_credentials WHERE name = N'$OpenAiEndpoint')
BEGIN
    DROP DATABASE SCOPED CREDENTIAL [$OpenAiEndpoint];
END
CREATE DATABASE SCOPED CREDENTIAL [$OpenAiEndpoint]
WITH IDENTITY = 'HTTPEndpointHeaders',
SECRET = '{"api-key":"$OpenAiKey"}';
"@

Write-Output "Step 2: Registering external embedding model..."
Invoke-Sql -Query @"
IF EXISTS (SELECT 1 FROM sys.external_models WHERE name = 'EmbeddingModel')
BEGIN
    DROP EXTERNAL MODEL EmbeddingModel;
END
CREATE EXTERNAL MODEL EmbeddingModel
WITH (
    LOCATION = '$($OpenAiEndpoint)openai/deployments/$($OpenAiDeployment)/embeddings?api-version=2023-05-15',
    API_FORMAT = 'Azure OpenAI',
    MODEL_TYPE = EMBEDDINGS,
    MODEL = '$OpenAiDeployment',
    CREDENTIAL = [$OpenAiEndpoint]
);
"@

Write-Output "Step 3: Ensuring tables exist..."
Invoke-Sql -Query @"
IF OBJECT_ID('dbo.FAQ_Content', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.FAQ_Content (
        faq_id   INT IDENTITY(1,1) PRIMARY KEY,
        category NVARCHAR(100) NOT NULL,
        question NVARCHAR(500) NOT NULL,
        answer   NVARCHAR(MAX) NOT NULL
    );
END
"@

Invoke-Sql -Query @"
IF OBJECT_ID('dbo.FAQ_Embeddings', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.FAQ_Embeddings (
        faq_id    INT PRIMARY KEY,
        embedding VECTOR($EmbeddingDimensions) NOT NULL,
        FOREIGN KEY (faq_id) REFERENCES dbo.FAQ_Content(faq_id)
    );
END
"@

Write-Output "Step 4: Inserting FAQ data (60 rows, skips any already present)..."
Invoke-Sql -Query @"
MERGE dbo.FAQ_Content AS target
USING (VALUES
    -- Orders (10)
    (N'Orders', N'How do I return a damaged item?', N'Start a return from Order History within 30 days and select "Damaged item" as the reason. We will send a prepaid label and issue a refund or replacement once received.'),
    (N'Orders', N'What if I received the wrong item?', N'Contact support with your order number and a photo of the item. We will arrange a free return and ship the correct item at no extra cost.'),
    (N'Orders', N'How do I track my order?', N'You can track your order from the Order History page. Select the order and choose "Track Package" to see live carrier updates.'),
    (N'Orders', N'Can I cancel an order after placing it?', N'Orders can be canceled within 1 hour of placement from Order History. After that, the order may have already entered processing and cannot be canceled.'),
    (N'Orders', N'How do I change my shipping address after ordering?', N'If the order has not yet shipped, you can update the address from Order History. Once shipped, contact support to redirect the package if the carrier allows it.'),
    (N'Orders', N'What happens if my order is lost in transit?', N'If tracking shows no movement for 5+ business days, contact support and we will open a carrier investigation and issue a replacement or refund.'),
    (N'Orders', N'Can I combine multiple orders into one shipment?', N'Orders placed separately are processed independently and cannot be combined once submitted, even if placed on the same day.'),
    (N'Orders', N'How do I reorder a previous purchase?', N'Go to Order History, select the past order, and choose "Buy Again" to add the same items to your cart.'),
    (N'Orders', N'Why was my order canceled automatically?', N'Orders are auto-canceled if payment fails verification or if an item goes out of stock before processing completes.'),
    (N'Orders', N'Can I add items to an order after checkout?', N'Once an order is placed it cannot be modified. Add the item to a new order or contact support if the original order has not yet shipped.'),
    -- Shipping (8)
    (N'Shipping', N'How long does delivery take?', N'Standard delivery takes 3-5 business days. Expedited shipping options are available at checkout for 1-2 business day delivery.'),
    (N'Shipping', N'Do you ship internationally?', N'Yes, we ship to over 40 countries. International delivery times and customs fees vary by destination and are shown at checkout.'),
    (N'Shipping', N'What are the shipping costs?', N'Standard shipping is free on orders over $50. Orders below that threshold have a flat $5.99 shipping fee.'),
    (N'Shipping', N'Can I choose a specific delivery date?', N'Scheduled delivery windows are available at checkout for select postal codes using our premium delivery option.'),
    (N'Shipping', N'What carriers do you use for delivery?', N'We use UPS, FedEx, and regional postal services depending on your location and the shipping method selected.'),
    (N'Shipping', N'Is signature required for delivery?', N'Signature is required only for orders over $200 or items marked as high-value at checkout.'),
    (N'Shipping', N'Can I pick up my order in-store instead of delivery?', N'Yes, select "Store Pickup" at checkout if available at your nearest location. You will be notified by email once it is ready.'),
    (N'Shipping', N'What if no one is home during delivery?', N'The carrier will leave the package in a safe location or attempt redelivery, depending on carrier policy and your delivery instructions.'),
    -- Payments (8)
    (N'Payments', N'What payment methods are accepted?', N'We accept major credit/debit cards, PayPal, and Apple Pay. Cryptocurrency is not currently supported.'),
    (N'Payments', N'Is it safe to save my card details?', N'Yes, saved cards are tokenized and stored securely by our PCI-compliant payment processor; we never store raw card numbers.'),
    (N'Payments', N'Can I pay in installments?', N'Installment payments are available through our checkout partner for orders over $100, split into 4 interest-free payments.'),
    (N'Payments', N'Why was my payment declined?', N'Declines usually come from your bank due to insufficient funds, incorrect billing details, or a temporary fraud hold. Contact your bank or try another payment method.'),
    (N'Payments', N'Can I use multiple gift cards on one order?', N'Yes, up to 3 gift cards can be applied per order at checkout.'),
    (N'Payments', N'How do I update my billing information?', N'Go to Account Settings > Payment Methods to add, remove, or update your saved billing details.'),
    (N'Payments', N'Do you accept cryptocurrency?', N'Cryptocurrency is not currently supported as a payment method.'),
    (N'Payments', N'Can I get an invoice for my purchase?', N'Yes, an itemized invoice is available for download from Order History under each order''s details page.'),
    -- Returns (8)
    (N'Returns', N'What is the return window?', N'Items can be returned within 30 days of delivery for a full refund, provided they are unused and in original packaging.'),
    (N'Returns', N'How do I start a return?', N'Go to Order History, select the item, and choose "Start a Return" to generate a prepaid shipping label.'),
    (N'Returns', N'Do I have to pay for return shipping?', N'Return shipping is free for defective or incorrect items. For other reasons, a small return label fee may apply.'),
    (N'Returns', N'How long does a refund take to process?', N'Refunds are issued within 3-5 business days of us receiving the returned item, and may take a few more days to appear on your statement.'),
    (N'Returns', N'Can I exchange an item instead of returning it?', N'Yes, select "Exchange" instead of "Refund" during the return process to receive a different size or color.'),
    (N'Returns', N'What items are non-returnable?', N'Final sale items, personalized products, and opened hygiene products are not eligible for return.'),
    (N'Returns', N'Can I return a gift without a receipt?', N'Yes, gift returns can be processed using the gift order number provided at checkout, without needing the original receipt.'),
    (N'Returns', N'What if my return is rejected?', N'If a returned item does not meet return criteria, it will be shipped back to you with an explanation from our returns team.'),
    -- Account (7)
    (N'Account', N'How do I reset my password?', N'Select "Forgot Password" on the sign-in page and follow the emailed link to set a new password.'),
    (N'Account', N'How do I update my email address?', N'Go to Account Settings > Profile to update your email address; a verification link will be sent to confirm the change.'),
    (N'Account', N'Can I delete my account?', N'Yes, account deletion can be requested from Account Settings > Privacy, or by contacting support directly.'),
    (N'Account', N'How do I enable two-factor authentication?', N'Go to Account Settings > Security and toggle on two-factor authentication, then follow the setup steps for your authenticator app.'),
    (N'Account', N'Why was my account locked?', N'Accounts are temporarily locked after multiple failed sign-in attempts as a security measure. Reset your password to unlock it.'),
    (N'Account', N'Can I merge two accounts?', N'Account merging is not supported automatically; contact support with both account emails and we can manually consolidate order history.'),
    (N'Account', N'How do I update my saved addresses?', N'Go to Account Settings > Addresses to add, edit, or remove saved shipping addresses.'),
    -- Product (7)
    (N'Product', N'How do I know if an item is in stock?', N'In-stock status is shown on the product page in real time; out-of-stock items display an estimated restock date if available.'),
    (N'Product', N'Can I get notified when an item is back in stock?', N'Yes, select "Notify Me" on the product page and we will email you as soon as it is back in stock.'),
    (N'Product', N'Where can I find size charts?', N'Size charts are available on each product page under the "Size Guide" tab, specific to that item''s category.'),
    (N'Product', N'Are product images accurate to the actual item?', N'Yes, images are of the actual product; slight color variation may occur due to display settings and lighting.'),
    (N'Product', N'How do I read product reviews?', N'Scroll to the Reviews section on any product page to see verified buyer ratings, comments, and photos.'),
    (N'Product', N'Can I request a product that is not listed?', N'Yes, use the "Request a Product" form in the Help Center and our merchandising team will review it.'),
    (N'Product', N'How do I compare similar products?', N'Select "Compare" on multiple product pages within the same category to view a side-by-side comparison table.'),
    -- Technical Support (6)
    (N'Technical Support', N'The website is not loading properly, what should I do?', N'Try clearing your browser cache, disabling extensions, or switching browsers. Contact support if the issue continues.'),
    (N'Technical Support', N'Why can''t I add items to my cart?', N'This is usually caused by the item going out of stock in real time or a temporary session issue; refresh the page and try again.'),
    (N'Technical Support', N'The app keeps crashing, how do I fix it?', N'Update to the latest app version from your device''s app store, then restart your device if the issue persists.'),
    (N'Technical Support', N'Why am I not receiving order confirmation emails?', N'Check your spam/junk folder and verify the email on file is correct in Account Settings > Profile.'),
    (N'Technical Support', N'How do I clear my browser cache for the site?', N'This depends on your browser; generally found under Settings > Privacy > Clear Browsing Data, selecting cached images and files.'),
    (N'Technical Support', N'Why is checkout failing repeatedly?', N'Checkout failures are often due to an expired card, browser extension conflicts, or an unstable connection; try a different browser or payment method.'),
    -- Warranty (3)
    (N'Warranty', N'What is covered under the product warranty?', N'Our standard warranty covers manufacturing defects in materials and workmanship under normal use.'),
    (N'Warranty', N'How long is the warranty period?', N'Most products carry a 1-year limited warranty from the date of purchase; electronics may have extended coverage options.'),
    (N'Warranty', N'How do I file a warranty claim?', N'Submit a warranty claim from Order History by selecting the item and choosing "File a Warranty Claim," along with a description of the issue.'),
    -- Promotions (3)
    (N'Promotions', N'How do I apply a promo code?', N'Enter your promo code in the "Promo Code" field at checkout before completing payment, then select "Apply."'),
    (N'Promotions', N'Why isn''t my discount code working?', N'Check the code''s expiration date and minimum purchase requirement; some codes also exclude sale items or specific categories.'),
    (N'Promotions', N'Can I combine multiple promo codes?', N'Only one promo code can be applied per order; the system will automatically use the highest-value discount if multiple are entered.')
) AS source (category, question, answer)
ON target.category = source.category AND target.question = source.question
WHEN NOT MATCHED THEN
    INSERT (category, question, answer) VALUES (source.category, source.question, source.answer);
"@

Write-Output "Step 5: Generating embeddings for rows missing one..."
Invoke-Sql -Query @"
INSERT INTO dbo.FAQ_Embeddings (faq_id, embedding)
SELECT c.faq_id, AI_GENERATE_EMBEDDINGS(c.question USE MODEL EmbeddingModel)
FROM dbo.FAQ_Content c
LEFT JOIN dbo.FAQ_Embeddings e ON e.faq_id = c.faq_id
WHERE e.faq_id IS NULL;
"@

Write-Output "Step 6: Creating/refreshing dbo.SearchFAQ..."
Invoke-Sql -Query @"
CREATE OR ALTER PROCEDURE dbo.SearchFAQ
    @user_question NVARCHAR(1000)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @q_vector VECTOR($EmbeddingDimensions);
    SET @q_vector = AI_GENERATE_EMBEDDINGS(@user_question USE MODEL EmbeddingModel);

    SELECT TOP 3
        c.faq_id, c.category, c.question, c.answer,
        VECTOR_DISTANCE('cosine', @q_vector, e.embedding) AS distance
    FROM dbo.FAQ_Embeddings AS e
    JOIN dbo.FAQ_Content AS c ON c.faq_id = e.faq_id
    ORDER BY distance ASC;
END
"@

Write-Output "Verification:"
Invoke-Sql -Query "SELECT COUNT(*) AS faq_count FROM dbo.FAQ_Content;" | Format-Table
Invoke-Sql -Query "SELECT COUNT(*) AS embedding_count FROM dbo.FAQ_Embeddings;" | Format-Table

Write-Output "Done. Test with: EXEC dbo.SearchFAQ @user_question = N'My product arrived damaged';"
