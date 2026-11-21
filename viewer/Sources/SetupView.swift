import SwiftUI

struct SetupView: View {
    @EnvironmentObject private var settings: ViewerSettings

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://android.amgm.jp/", text: $settings.serverURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("接続先")
                }
                Section {
                    SecureField("パスワード", text: $settings.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("パスワード")
                } footer: {
                    Text("サーバーのセットアップの最後に表示されたパスワードを入れてください。")
                }
                Section {
                    Button("接続する") { settings.save() }
                        .disabled(settings.password.isEmpty || settings.serverURL.isEmpty)
                }
            }
            .navigationTitle("Android")
        }
    }
}
