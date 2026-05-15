describe("iOS bridge module", function()
    setup(function()
        require("commonrequire")
    end)

    it("does not throw when native bridge symbols are unavailable", function()
        local old_path = package.path
        local old_ios = package.loaded.ios
        package.loaded.ios = nil
        package.path = "../../platform/ios/?.lua;" .. old_path

        local ok, ios = pcall(require, "ios")
        package.path = old_path
        package.loaded.ios = old_ios

        assert.is_true(ok, ios)
        local insets_ok, insets = pcall(function()
            return ios.getSafeAreaInsets()
        end)
        assert.is_true(insets_ok, insets)
        assert.is_table(insets)

        local import_ok, status = pcall(function()
            return ios.getPluginZipImportResult()
        end)
        assert.is_true(import_ok, status)
        assert.is_string(status)

        local file_import_ok, file_import_status = pcall(function()
            return ios.getFileImportResult()
        end)
        assert.is_true(file_import_ok, file_import_status)
        assert.is_string(file_import_status)

        local folder_picker_ok, folder_picker_status = pcall(function()
            return ios.getExternalFolderPickerResult()
        end)
        assert.is_true(folder_picker_ok, folder_picker_status)
        assert.is_string(folder_picker_status)
    end)
end)
