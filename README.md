# Trend King EA - GitHub Authorization Setup

## 1. Create GitHub Repository
1. Log in to your GitHub account.
2. Create a new **Public** repository named `Trend-King-EA`.
3. Upload the `accounts.txt` file from this folder.
   - Add allowed MT5 Account Numbers (one per line).
4. Click on `accounts.txt` in GitHub, then click the **Raw** button.
5. Copy the URL. It should look like:
   `https://raw.githubusercontent.com/<YourUsername>/Trend-King-EA/main/accounts.txt`

## 2. Configure MT5
1. Open MetaTrader 5.
2. Go to **Tools > Options > Expert Advisors**.
3. Check **"Allow WebRequest for listed URL"**.
4. Add `https://raw.githubusercontent.com` to the list.
5. Click OK.

## 3. Configure EA
1. Load `Trend_King_EA` on a chart.
2. In the Inputs tab, paste your Raw URL into the `InpAuthUrl` field.
3. Click OK.

The EA will now check your GitHub file on startup. If the account number is not in the list, it will alert and remove itself.
