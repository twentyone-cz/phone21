package cz.twentyone.dialer;

import android.content.Intent;
import android.content.SharedPreferences;
import android.net.Uri;
import android.telecom.Connection;
import android.telecom.ConnectionRequest;
import android.telecom.ConnectionService;
import android.telecom.DisconnectCause;
import android.telecom.PhoneAccountHandle;
import android.util.Log;

/**
 * Most mezi systémem a softphonem.
 *
 * Systém sem pošle požadavek na hovor, který vznikl mimo aplikaci — typicky
 * když se vytáčí z auta přes Bluetooth. Hovor samotný neneseme: číslo předáme
 * softphonu a vlastní spojení hned zrušíme, takže v systému zůstane jediný
 * hovor, ten softphonový (stejný postup používá i Linphone pro svoje
 * přesměrování). Auto pak vidí normální hovor včetně ovládání z volantu.
 */
public class GatewayConnectionService extends ConnectionService {

    private static final String TAG = "jednadvacet-dialer";

    @Override
    public Connection onCreateOutgoingConnection(PhoneAccountHandle account,
                                                 ConnectionRequest request) {
        Uri address = request != null ? request.getAddress() : null;
        Log.i(TAG, "požadavek na hovor: " + address);

        String number = numberFrom(address);
        if (number == null || number.isEmpty()) {
            Log.w(TAG, "požadavek bez použitelného čísla");
            return Connection.createFailedConnection(
                    new DisconnectCause(DisconnectCause.ERROR));
        }

        SharedPreferences prefs = getSharedPreferences(MainActivity.PREFS, MODE_PRIVATE);
        String cc = prefs.getString(MainActivity.PREF_COUNTRY_CODE, MainActivity.DEFAULT_COUNTRY_CODE);
        String e164 = Gateway.normalize(number, cc);

        if (!Gateway.softphoneInstalled(this)) {
            Log.e(TAG, "softphone není nainstalovaný");
            return Connection.createFailedConnection(
                    new DisconnectCause(DisconnectCause.ERROR));
        }

        try {
            Log.i(TAG, "předávám softphonu: " + e164);
            startActivity(Gateway.callIntent(e164));
        } catch (Exception e) {
            Log.e(TAG, "předání softphonu selhalo: " + e);
            return Connection.createFailedConnection(
                    new DisconnectCause(DisconnectCause.ERROR));
        }

        // Hovor od teď vede softphone; naše spojení rušíme, ať v systému
        // nezůstane viset druhý (a v seznamu hovorů prázdný záznam).
        return Connection.createCanceledConnection();
    }

    @Override
    public void onCreateOutgoingConnectionFailed(PhoneAccountHandle account,
                                                 ConnectionRequest request) {
        Log.w(TAG, "systém odmítl odchozí spojení: "
                + (request != null ? request.getAddress() : null));
    }

    @Override
    public Connection onCreateIncomingConnection(PhoneAccountHandle account,
                                                 ConnectionRequest request) {
        // Příchozí hovory chodí přímo do softphonu, tudy nikdy nepůjdou.
        return Connection.createFailedConnection(
                new DisconnectCause(DisconnectCause.ERROR));
    }

    /** Z tel:/sip: adresy vytáhne to, co se dá vytočit. */
    static String numberFrom(Uri address) {
        if (address == null) {
            return null;
        }
        String part = address.getSchemeSpecificPart();
        if (part == null) {
            return null;
        }
        int at = part.indexOf('@');
        if (at > 0) {
            part = part.substring(0, at);   // sip:cislo@domena → cislo
        }
        return Uri.decode(part).trim();
    }
}
