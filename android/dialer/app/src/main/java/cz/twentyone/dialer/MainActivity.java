package cz.twentyone.dialer;

import android.Manifest;
import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.net.Uri;
import android.os.Bundle;
import android.telecom.TelecomManager;
import android.text.InputType;
import android.util.TypedValue;
import android.view.View;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

/** Jediná obrazovka: stav účtu, nastavení předvolby a zkušební hovor. */
public class MainActivity extends Activity {

    public static final String PREFS = "dialer";
    public static final String PREF_COUNTRY_CODE = "country_code";
    public static final String DEFAULT_COUNTRY_CODE = "420";

    private static final int REQ_CALL = 1;

    private TextView status;
    private EditText countryCode;
    private EditText testNumber;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        int pad = dp(20);
        root.setPadding(pad, pad, pad, pad);

        root.addView(heading(getString(R.string.app_name)));
        root.addView(body(getString(R.string.intro)));

        status = body("");
        status.setPadding(0, dp(12), 0, dp(12));
        root.addView(status);

        root.addView(button(getString(R.string.btn_register), v -> {
            try {
                Gateway.register(this);
                toast(getString(R.string.registered));
            } catch (SecurityException e) {
                toast(getString(R.string.register_failed) + " " + e.getMessage());
            }
            refresh();
        }));

        root.addView(button(getString(R.string.btn_accounts), v -> {
            try {
                startActivity(new Intent("android.settings.PHONE_ACCOUNT_SETTINGS"));
            } catch (Exception e) {
                toast(getString(R.string.settings_missing));
            }
        }));

        root.addView(label(getString(R.string.country_code)));
        countryCode = new EditText(this);
        countryCode.setInputType(InputType.TYPE_CLASS_NUMBER);
        root.addView(countryCode);

        root.addView(label(getString(R.string.test_call)));
        testNumber = new EditText(this);
        testNumber.setInputType(InputType.TYPE_CLASS_PHONE);
        testNumber.setHint("739 000 000");
        root.addView(testNumber);

        root.addView(button(getString(R.string.btn_test), v -> placeTestCall()));
        root.addView(body(getString(R.string.test_hint)));

        ScrollView scroll = new ScrollView(this);
        scroll.addView(root);
        setContentView(scroll);
    }

    @Override
    protected void onResume() {
        super.onResume();
        SharedPreferences prefs = getSharedPreferences(PREFS, MODE_PRIVATE);
        countryCode.setText(prefs.getString(PREF_COUNTRY_CODE, DEFAULT_COUNTRY_CODE));
        refresh();
    }

    @Override
    protected void onPause() {
        super.onPause();
        String cc = countryCode.getText().toString().trim();
        if (!cc.isEmpty()) {
            getSharedPreferences(PREFS, MODE_PRIVATE).edit()
                    .putString(PREF_COUNTRY_CODE, cc).apply();
        }
    }

    private void refresh() {
        StringBuilder sb = new StringBuilder();
        sb.append(getString(R.string.state_softphone)).append(' ')
                .append(Gateway.softphoneInstalled(this)
                        ? getString(R.string.yes) : getString(R.string.no_softphone))
                .append('\n');
        sb.append(getString(R.string.state_account)).append(' ')
                .append(Gateway.isRegistered(this)
                        ? getString(R.string.yes) : getString(R.string.not_yet))
                .append('\n');
        sb.append(getString(R.string.state_enabled)).append(' ')
                .append(Gateway.isEnabled(this)
                        ? getString(R.string.yes) : getString(R.string.enable_in_settings));
        status.setText(sb.toString());
    }

    /**
     * Vytočí přes NÁŠ účet — tedy stejnou cestou, jakou hovor přijde z auta.
     * Bez auta se tím dá celý řetěz otestovat na stole.
     */
    private void placeTestCall() {
        String raw = testNumber.getText().toString().trim();
        if (raw.isEmpty()) {
            toast(getString(R.string.no_number));
            return;
        }
        if (checkSelfPermission(Manifest.permission.CALL_PHONE) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[]{Manifest.permission.CALL_PHONE}, REQ_CALL);
            return;
        }
        String cc = countryCode.getText().toString().trim();
        String e164 = Gateway.normalize(raw, cc.isEmpty() ? DEFAULT_COUNTRY_CODE : cc);

        TelecomManager tm = (TelecomManager) getSystemService(Context.TELECOM_SERVICE);
        Bundle extras = new Bundle();
        extras.putParcelable(TelecomManager.EXTRA_PHONE_ACCOUNT_HANDLE, Gateway.handle(this));
        try {
            tm.placeCall(Uri.fromParts("tel", e164, null), extras);
        } catch (SecurityException | IllegalStateException e) {
            toast(getString(R.string.call_failed) + " " + e.getMessage());
        }
    }

    @Override
    public void onRequestPermissionsResult(int code, String[] perms, int[] results) {
        if (code == REQ_CALL && results.length > 0
                && results[0] == PackageManager.PERMISSION_GRANTED) {
            placeTestCall();
        }
    }

    // --- drobná pomoc s UI (appka nemá layouty, ať zůstane bez závislostí) ---

    private int dp(int value) {
        return (int) TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, value,
                getResources().getDisplayMetrics());
    }

    private TextView heading(String text) {
        TextView tv = new TextView(this);
        tv.setText(text);
        tv.setTextSize(TypedValue.COMPLEX_UNIT_SP, 22);
        tv.setPadding(0, 0, 0, dp(8));
        return tv;
    }

    private TextView body(String text) {
        TextView tv = new TextView(this);
        tv.setText(text);
        tv.setTextSize(TypedValue.COMPLEX_UNIT_SP, 14);
        return tv;
    }

    private TextView label(String text) {
        TextView tv = body(text);
        tv.setPadding(0, dp(16), 0, dp(4));
        tv.setTextColor(Color.GRAY);
        return tv;
    }

    private Button button(String text, View.OnClickListener listener) {
        Button b = new Button(this);
        b.setText(text);
        b.setOnClickListener(listener);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT);
        lp.topMargin = dp(8);
        b.setLayoutParams(lp);
        return b;
    }

    private void toast(String text) {
        Toast.makeText(this, text, Toast.LENGTH_LONG).show();
    }
}
