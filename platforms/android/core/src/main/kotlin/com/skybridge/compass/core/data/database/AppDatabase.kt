package com.skybridge.compass.core.data.database

import androidx.room.Database
import androidx.room.Room
import androidx.room.RoomDatabase
import androidx.room.TypeConverters
import android.content.Context
import com.skybridge.compass.core.data.dao.DeviceDao
import com.skybridge.compass.core.data.dao.ConnectionDao
import com.skybridge.compass.core.data.model.Device
import com.skybridge.compass.core.data.model.Connection

/**
 * SkyBridge Compass 应用数据库
 */
@Database(
    entities = [
        Device::class,
        Connection::class
    ],
    version = 1,
    exportSchema = false
)
@TypeConverters(Converters::class)
abstract class AppDatabase : RoomDatabase() {
    
    abstract fun deviceDao(): DeviceDao
    abstract fun connectionDao(): ConnectionDao
    
    companion object {
        const val DATABASE_NAME = "skybridge_compass_db"
        
        @Volatile
        private var INSTANCE: AppDatabase? = null
        
        fun getDatabase(context: Context): AppDatabase {
            return INSTANCE ?: synchronized(this) {
                val instance = Room.databaseBuilder(
                    context.applicationContext,
                    AppDatabase::class.java,
                    DATABASE_NAME
                )
                .build()
                INSTANCE = instance
                instance
            }
        }
    }
}
