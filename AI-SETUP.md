# The AI assistant (online only, optional paid add-on)

What it does
- **Suggest a name from a photo**: on the product screen, after you take a photo, tap "Suggest a name from the photo".
- **Ask**: type a question such as "How much is sugar?" or "How did we do today?". Phones show it as the "Ask" tile; the owner sees it on the web dashboard under "Ask".
- Selling never depends on it. Offline, these two features just say "You need internet".

## Turn it on (once, on your server)
**DeepSeek (cheap, recommended to start)**
1. Make an account at https://platform.deepseek.com, top up a small balance (a few dollars lasts a very long time), and create an API key. DeepSeek is very cheap but it is not free: the usage is paid from your balance.
2. Put the key in the server's environment before starting it. Windows PowerShell: `$env:DEEPSEEK_API_KEY = "sk-..."` then start the server in the same window.
3. The model is `deepseek-flash` by default; it reads product photos too.

**Groq (has a free plan)**: make an account at https://console.groq.com, create an API key, and run `$env:GROQ_API_KEY = "gsk_..."` before starting the server. The default model is `qwen/qwen3.8-27b` (reads photos). The free plan is rate limited (roughly 1,000 requests a day and 8,000 tokens a minute per model), so the server sends a shorter shop summary. If several keys are set, Groq is used first, then DeepSeek, then Claude.

**Claude (alternative)**: set `ANTHROPIC_API_KEY` instead. If both are set, DeepSeek is used.

Optional: `AI_MODEL` to change the model, `AI_MONTHLY_LIMIT` (questions per shop per month, default 300, counted separately for photos and questions).

Never put a key in the app, in GitHub, or in a chat. Only the server holds it. With no key the feature shows "not switched on yet".

## Sell it per shop
The assistant is a licence option called `ai`. In the vendor dashboard, open the shop, edit the licence features and add `ai` (comma separated, for example `ai`). Shops without it see "not part of your plan". You can also add `ai` to a Plan so new licences get it.

## Cost control
- Each shop has a monthly limit; failed answers are not counted.
- The photo is sent only when someone taps the button; the question sends a short text summary of that shop's products, prices and stock (and sales only for people allowed to see reports).
- Price the add-on above your expected cost per shop, and watch your usage in the Anthropic console.

## Privacy note for your shops
Questions, photos and the text summary go to the AI company (DeepSeek, whose servers are in China, or Anthropic) to be answered. Tell shop owners this in your terms.
