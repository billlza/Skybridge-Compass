package com.skybridge.compass.discovery.data.datasources

import com.skybridge.compass.discovery.data.interop.AppleBonjourInterop
import io.kotest.core.spec.style.FunSpec
import io.kotest.matchers.shouldBe

class BonjourServiceTypePolicyTest : FunSpec({

    test("accepts Android leading-dot aliases for the requested service type") {
        matchesBonjourServiceType(
            requestedServiceType = AppleBonjourInterop.FILE_TRANSFER_SERVICE_TYPE,
            resolvedServiceType = ".${AppleBonjourInterop.FILE_TRANSFER_SERVICE_TYPE}"
        ) shouldBe true
    }

    test("accepts a legacy alias when the listener requested its canonical route") {
        matchesBonjourServiceType(
            requestedServiceType = AppleBonjourInterop.FILE_TRANSFER_SERVICE_TYPE,
            resolvedServiceType = ".${AppleBonjourInterop.LEGACY_FILE_TRANSFER_SERVICE_TYPE}."
        ) shouldBe true
    }

    test("rejects a resolved service from a different known route") {
        matchesBonjourServiceType(
            requestedServiceType = AppleBonjourInterop.FILE_TRANSFER_SERVICE_TYPE,
            resolvedServiceType = AppleBonjourInterop.REMOTE_SERVICE_TYPE
        ) shouldBe false
    }

    test("rejects unknown, malformed, and missing service types") {
        matchesBonjourServiceType(
            requestedServiceType = AppleBonjourInterop.FILE_TRANSFER_SERVICE_TYPE,
            resolvedServiceType = "._unknown._tcp"
        ) shouldBe false
        matchesBonjourServiceType(
            requestedServiceType = AppleBonjourInterop.FILE_TRANSFER_SERVICE_TYPE,
            resolvedServiceType = "..${AppleBonjourInterop.FILE_TRANSFER_SERVICE_TYPE}"
        ) shouldBe false
        matchesBonjourServiceType(
            requestedServiceType = AppleBonjourInterop.FILE_TRANSFER_SERVICE_TYPE,
            resolvedServiceType = null
        ) shouldBe false
    }

    test("uses one index key for canonical and Android leading-dot service types") {
        val serviceName = "MacBook Pro"

        canonicalBonjourServiceKey(
            serviceType = AppleBonjourInterop.FILE_TRANSFER_SERVICE_TYPE,
            serviceName = serviceName
        ) shouldBe canonicalBonjourServiceKey(
            serviceType = ".${AppleBonjourInterop.FILE_TRANSFER_SERVICE_TYPE}",
            serviceName = serviceName
        )
    }
})
