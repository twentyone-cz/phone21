package cz.twentyone.dialer;

import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.net.Uri;
import android.telecom.PhoneAccount;
import android.telecom.PhoneAccountHandle;
import android.telecom.TelecomManager;

import java.util.Arrays;

/** Registrace telefonního účtu a normalizace čísel. */
public final class Gateway {

    /** Softphone, který hovor skutečně uskuteční. */
    public static final String SOFTPHONE_PACKAGE = "org.linphone";

    private static final String ACCOUNT_ID = "jednadvacet-gateway";

    private Gateway() {
    }

    public static PhoneAccountHandle handle(Context ctx) {
        return new PhoneAccountHandle(
                new ComponentName(ctx, GatewayConnectionService.class), ACCOUNT_ID);
    }

    /**
     * Účet s CAPABILITY_CALL_PROVIDER — tím se odliší od „self-managed" účtu,
     * jaký si registruje samotný softphone. Jen účet téhle kategorie systém
     * osloví, když hovor vzniká mimo aplikaci (typicky vytáčení z auta přes
     * Bluetooth: auto pošle číslo, Android hledá telefonní účet).
     */
    public static void register(Context ctx) {
        TelecomManager tm = (TelecomManager) ctx.getSystemService(Context.TELECOM_SERVICE);
        PhoneAccount account = PhoneAccount.builder(handle(ctx), ctx.getString(R.string.account_label))
                .setCapabilities(PhoneAccount.CAPABILITY_CALL_PROVIDER)
                .setShortDescription(ctx.getString(R.string.account_description))
                .setSupportedUriSchemes(Arrays.asList(
                        PhoneAccount.SCHEME_TEL, PhoneAccount.SCHEME_SIP))
                .build();
        tm.registerPhoneAccount(account);
    }

    public static void unregister(Context ctx) {
        TelecomManager tm = (TelecomManager) ctx.getSystemService(Context.TELECOM_SERVICE);
        tm.unregisterPhoneAccount(handle(ctx));
    }

    /** Je účet zaregistrovaný a uživatelem povolený v Účtech pro volání? */
    public static boolean isEnabled(Context ctx) {
        TelecomManager tm = (TelecomManager) ctx.getSystemService(Context.TELECOM_SERVICE);
        try {
            for (PhoneAccountHandle h : tm.getCallCapablePhoneAccounts()) {
                if (h.equals(handle(ctx))) {
                    return true;
                }
            }
        } catch (SecurityException ignored) {
            // bez READ_PHONE_STATE vrací systém prázdný seznam
        }
        return false;
    }

    public static boolean isRegistered(Context ctx) {
        TelecomManager tm = (TelecomManager) ctx.getSystemService(Context.TELECOM_SERVICE);
        return tm.getPhoneAccount(handle(ctx)) != null;
    }

    public static boolean softphoneInstalled(Context ctx) {
        try {
            ctx.getPackageManager().getPackageInfo(SOFTPHONE_PACKAGE, 0);
            return true;
        } catch (Exception e) {
            return false;
        }
    }

    /**
     * Předání hovoru softphonu. Schéma linphone-sip: si vezme jen on, takže
     * se hovor nemůže vrátit zpátky do systému a zacyklit; doménu brány si
     * doplní sám podle svého účtu, nemusíme ji tedy vůbec znát.
     */
    public static Intent callIntent(String e164) {
        Intent intent = new Intent(Intent.ACTION_VIEW, Uri.parse("linphone-sip:" + e164));
        intent.setPackage(SOFTPHONE_PACKAGE);
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        return intent;
    }

    /**
     * Normalizace na E.164 — STEJNÁ pravidla jako subrutina [number-normalize]
     * v dialplanu brány a normalize_msisdn() ve web UI; při změně upravit
     * všechna tři místa. Krátká a nečíselná čísla vrací beze změny.
     */
    public static String normalize(String number, String countryCode) {
        if (number == null) {
            return null;
        }
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < number.length(); i++) {
            char c = number.charAt(i);
            if (Character.isDigit(c) || (c == '+' && sb.length() == 0)) {
                sb.append(c);
            }
        }
        String n = sb.toString();
        if (n.isEmpty() || n.startsWith("+")) {
            return n;
        }
        if (n.startsWith("00") && n.length() > 4) {
            return "+" + n.substring(2);
        }
        if (n.startsWith(countryCode) && n.length() == countryCode.length() + 9) {
            return "+" + n;
        }
        if (n.length() == 9) {
            return "+" + countryCode + n;
        }
        return n;
    }
}
