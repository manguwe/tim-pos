# The AI assistant (online only, optional paid add-on)

What it does
- **Suggest a name from a photo**: on the product screen, after you take a photo, tap "Suggest a name from the photo".
- **Ask**: type a question such as "How much is sugar?" or "How did we do today?". Phones show it as the "Ask" tile; the owner sees it on the web dashboard under "Ask".
- Selling never depends on it. Offline, these two features just say "You need internet".

## Turn it on (once, on your server)
1. Make an account at https://console.anthropic.com and add a little credit (a few dollars is plenty to start). Create an API key.
2. Put the key in the server's environment before starting it:
   - Windows PowerShell: `$env:ANTHROPIC_API_KEY = "sk-ant-..."` then start the server in the same window.
   - Optional: `AI_MODEL` (default `claude-haiku-5-5`, the cheapest) and `AI_MONTHLY_LIMIT` (questions per shop per month, default 300, counted separately for photos and questions).
3. Never put the key in the app, in GitHub, or in a chat. Only the server holds it. If the key is missing, the feature simply shows "not switched on yet".

## Sell it per shop
The assistant is a licence option called `ai`. In the vendor dashboard, open the shop, edit the licence features and add `ai` (comma separated, for example `ai`). Shops without it see "not part of your plan". You can also add `ai` to a Plan so new licences get it.

## Cost control
- Each shop has a monthly limit; failed answers are not counted.
- The photo is sent only when someone taps the button; the question sends a short text summary of that shop's products, prices and stock (and sales only for people allowed to see reports).
- Price the add-on above your expected cost per shop, and watch your usage in the Anthropic console.

## Privacy note for your shops
Questions and the text summary go to Anthropic to be answered. Tell shop owners this in your terms.
