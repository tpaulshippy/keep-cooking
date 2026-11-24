package com.keepcooking.app.data;

import android.database.Cursor;
import android.os.CancellationSignal;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.room.CoroutinesRoom;
import androidx.room.EntityInsertionAdapter;
import androidx.room.RoomDatabase;
import androidx.room.RoomSQLiteQuery;
import androidx.room.util.CursorUtil;
import androidx.room.util.DBUtil;
import androidx.sqlite.db.SupportSQLiteStatement;
import java.lang.Class;
import java.lang.Double;
import java.lang.Exception;
import java.lang.Integer;
import java.lang.Object;
import java.lang.Override;
import java.lang.String;
import java.lang.SuppressWarnings;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.concurrent.Callable;
import javax.annotation.processing.Generated;
import kotlin.Unit;
import kotlin.coroutines.Continuation;

@Generated("androidx.room.RoomProcessor")
@SuppressWarnings({"unchecked", "deprecation"})
public final class RecipeDao_Impl implements RecipeDao {
  private final RoomDatabase __db;

  private final EntityInsertionAdapter<RecipeEntity> __insertionAdapterOfRecipeEntity;

  public RecipeDao_Impl(@NonNull final RoomDatabase __db) {
    this.__db = __db;
    this.__insertionAdapterOfRecipeEntity = new EntityInsertionAdapter<RecipeEntity>(__db) {
      @Override
      @NonNull
      protected String createQuery() {
        return "INSERT OR REPLACE INTO `recipes` (`id`,`householdId`,`title`,`recipeDescription`,`servings`,`prepMinutes`,`cookMinutes`,`rating`,`source`,`sourceUrl`,`categoriesJson`,`photoOriginal`,`photoLarge1024`,`photoThumb`,`updatedAt`,`deviceId`,`deleted`) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)";
      }

      @Override
      protected void bind(@NonNull final SupportSQLiteStatement statement,
          @NonNull final RecipeEntity entity) {
        statement.bindString(1, entity.getId());
        statement.bindString(2, entity.getHouseholdId());
        statement.bindString(3, entity.getTitle());
        statement.bindString(4, entity.getRecipeDescription());
        statement.bindDouble(5, entity.getServings());
        if (entity.getPrepMinutes() == null) {
          statement.bindNull(6);
        } else {
          statement.bindLong(6, entity.getPrepMinutes());
        }
        if (entity.getCookMinutes() == null) {
          statement.bindNull(7);
        } else {
          statement.bindLong(7, entity.getCookMinutes());
        }
        if (entity.getRating() == null) {
          statement.bindNull(8);
        } else {
          statement.bindDouble(8, entity.getRating());
        }
        statement.bindString(9, entity.getSource());
        statement.bindString(10, entity.getSourceUrl());
        statement.bindString(11, entity.getCategoriesJson());
        if (entity.getPhotoOriginal() == null) {
          statement.bindNull(12);
        } else {
          statement.bindString(12, entity.getPhotoOriginal());
        }
        if (entity.getPhotoLarge1024() == null) {
          statement.bindNull(13);
        } else {
          statement.bindString(13, entity.getPhotoLarge1024());
        }
        if (entity.getPhotoThumb() == null) {
          statement.bindNull(14);
        } else {
          statement.bindString(14, entity.getPhotoThumb());
        }
        statement.bindLong(15, entity.getUpdatedAt());
        statement.bindString(16, entity.getDeviceId());
        final int _tmp = entity.getDeleted() ? 1 : 0;
        statement.bindLong(17, _tmp);
      }
    };
  }

  @Override
  public Object upsertAll(final List<RecipeEntity> rows,
      final Continuation<? super Unit> $completion) {
    return CoroutinesRoom.execute(__db, true, new Callable<Unit>() {
      @Override
      @NonNull
      public Unit call() throws Exception {
        __db.beginTransaction();
        try {
          __insertionAdapterOfRecipeEntity.insert(rows);
          __db.setTransactionSuccessful();
          return Unit.INSTANCE;
        } finally {
          __db.endTransaction();
        }
      }
    }, $completion);
  }

  @Override
  public Object upsert(final RecipeEntity row, final Continuation<? super Unit> $completion) {
    return CoroutinesRoom.execute(__db, true, new Callable<Unit>() {
      @Override
      @NonNull
      public Unit call() throws Exception {
        __db.beginTransaction();
        try {
          __insertionAdapterOfRecipeEntity.insert(row);
          __db.setTransactionSuccessful();
          return Unit.INSTANCE;
        } finally {
          __db.endTransaction();
        }
      }
    }, $completion);
  }

  @Override
  public Object liveRecipes(final Continuation<? super List<RecipeEntity>> $completion) {
    final String _sql = "SELECT * FROM recipes WHERE deleted = 0 ORDER BY updatedAt DESC";
    final RoomSQLiteQuery _statement = RoomSQLiteQuery.acquire(_sql, 0);
    final CancellationSignal _cancellationSignal = DBUtil.createCancellationSignal();
    return CoroutinesRoom.execute(__db, false, _cancellationSignal, new Callable<List<RecipeEntity>>() {
      @Override
      @NonNull
      public List<RecipeEntity> call() throws Exception {
        final Cursor _cursor = DBUtil.query(__db, _statement, false, null);
        try {
          final int _cursorIndexOfId = CursorUtil.getColumnIndexOrThrow(_cursor, "id");
          final int _cursorIndexOfHouseholdId = CursorUtil.getColumnIndexOrThrow(_cursor, "householdId");
          final int _cursorIndexOfTitle = CursorUtil.getColumnIndexOrThrow(_cursor, "title");
          final int _cursorIndexOfRecipeDescription = CursorUtil.getColumnIndexOrThrow(_cursor, "recipeDescription");
          final int _cursorIndexOfServings = CursorUtil.getColumnIndexOrThrow(_cursor, "servings");
          final int _cursorIndexOfPrepMinutes = CursorUtil.getColumnIndexOrThrow(_cursor, "prepMinutes");
          final int _cursorIndexOfCookMinutes = CursorUtil.getColumnIndexOrThrow(_cursor, "cookMinutes");
          final int _cursorIndexOfRating = CursorUtil.getColumnIndexOrThrow(_cursor, "rating");
          final int _cursorIndexOfSource = CursorUtil.getColumnIndexOrThrow(_cursor, "source");
          final int _cursorIndexOfSourceUrl = CursorUtil.getColumnIndexOrThrow(_cursor, "sourceUrl");
          final int _cursorIndexOfCategoriesJson = CursorUtil.getColumnIndexOrThrow(_cursor, "categoriesJson");
          final int _cursorIndexOfPhotoOriginal = CursorUtil.getColumnIndexOrThrow(_cursor, "photoOriginal");
          final int _cursorIndexOfPhotoLarge1024 = CursorUtil.getColumnIndexOrThrow(_cursor, "photoLarge1024");
          final int _cursorIndexOfPhotoThumb = CursorUtil.getColumnIndexOrThrow(_cursor, "photoThumb");
          final int _cursorIndexOfUpdatedAt = CursorUtil.getColumnIndexOrThrow(_cursor, "updatedAt");
          final int _cursorIndexOfDeviceId = CursorUtil.getColumnIndexOrThrow(_cursor, "deviceId");
          final int _cursorIndexOfDeleted = CursorUtil.getColumnIndexOrThrow(_cursor, "deleted");
          final List<RecipeEntity> _result = new ArrayList<RecipeEntity>(_cursor.getCount());
          while (_cursor.moveToNext()) {
            final RecipeEntity _item;
            final String _tmpId;
            _tmpId = _cursor.getString(_cursorIndexOfId);
            final String _tmpHouseholdId;
            _tmpHouseholdId = _cursor.getString(_cursorIndexOfHouseholdId);
            final String _tmpTitle;
            _tmpTitle = _cursor.getString(_cursorIndexOfTitle);
            final String _tmpRecipeDescription;
            _tmpRecipeDescription = _cursor.getString(_cursorIndexOfRecipeDescription);
            final double _tmpServings;
            _tmpServings = _cursor.getDouble(_cursorIndexOfServings);
            final Integer _tmpPrepMinutes;
            if (_cursor.isNull(_cursorIndexOfPrepMinutes)) {
              _tmpPrepMinutes = null;
            } else {
              _tmpPrepMinutes = _cursor.getInt(_cursorIndexOfPrepMinutes);
            }
            final Integer _tmpCookMinutes;
            if (_cursor.isNull(_cursorIndexOfCookMinutes)) {
              _tmpCookMinutes = null;
            } else {
              _tmpCookMinutes = _cursor.getInt(_cursorIndexOfCookMinutes);
            }
            final Double _tmpRating;
            if (_cursor.isNull(_cursorIndexOfRating)) {
              _tmpRating = null;
            } else {
              _tmpRating = _cursor.getDouble(_cursorIndexOfRating);
            }
            final String _tmpSource;
            _tmpSource = _cursor.getString(_cursorIndexOfSource);
            final String _tmpSourceUrl;
            _tmpSourceUrl = _cursor.getString(_cursorIndexOfSourceUrl);
            final String _tmpCategoriesJson;
            _tmpCategoriesJson = _cursor.getString(_cursorIndexOfCategoriesJson);
            final String _tmpPhotoOriginal;
            if (_cursor.isNull(_cursorIndexOfPhotoOriginal)) {
              _tmpPhotoOriginal = null;
            } else {
              _tmpPhotoOriginal = _cursor.getString(_cursorIndexOfPhotoOriginal);
            }
            final String _tmpPhotoLarge1024;
            if (_cursor.isNull(_cursorIndexOfPhotoLarge1024)) {
              _tmpPhotoLarge1024 = null;
            } else {
              _tmpPhotoLarge1024 = _cursor.getString(_cursorIndexOfPhotoLarge1024);
            }
            final String _tmpPhotoThumb;
            if (_cursor.isNull(_cursorIndexOfPhotoThumb)) {
              _tmpPhotoThumb = null;
            } else {
              _tmpPhotoThumb = _cursor.getString(_cursorIndexOfPhotoThumb);
            }
            final long _tmpUpdatedAt;
            _tmpUpdatedAt = _cursor.getLong(_cursorIndexOfUpdatedAt);
            final String _tmpDeviceId;
            _tmpDeviceId = _cursor.getString(_cursorIndexOfDeviceId);
            final boolean _tmpDeleted;
            final int _tmp;
            _tmp = _cursor.getInt(_cursorIndexOfDeleted);
            _tmpDeleted = _tmp != 0;
            _item = new RecipeEntity(_tmpId,_tmpHouseholdId,_tmpTitle,_tmpRecipeDescription,_tmpServings,_tmpPrepMinutes,_tmpCookMinutes,_tmpRating,_tmpSource,_tmpSourceUrl,_tmpCategoriesJson,_tmpPhotoOriginal,_tmpPhotoLarge1024,_tmpPhotoThumb,_tmpUpdatedAt,_tmpDeviceId,_tmpDeleted);
            _result.add(_item);
          }
          return _result;
        } finally {
          _cursor.close();
          _statement.release();
        }
      }
    }, $completion);
  }

  @Override
  public Object byId(final String id, final Continuation<? super RecipeEntity> $completion) {
    final String _sql = "SELECT * FROM recipes WHERE id = ? LIMIT 1";
    final RoomSQLiteQuery _statement = RoomSQLiteQuery.acquire(_sql, 1);
    int _argIndex = 1;
    _statement.bindString(_argIndex, id);
    final CancellationSignal _cancellationSignal = DBUtil.createCancellationSignal();
    return CoroutinesRoom.execute(__db, false, _cancellationSignal, new Callable<RecipeEntity>() {
      @Override
      @Nullable
      public RecipeEntity call() throws Exception {
        final Cursor _cursor = DBUtil.query(__db, _statement, false, null);
        try {
          final int _cursorIndexOfId = CursorUtil.getColumnIndexOrThrow(_cursor, "id");
          final int _cursorIndexOfHouseholdId = CursorUtil.getColumnIndexOrThrow(_cursor, "householdId");
          final int _cursorIndexOfTitle = CursorUtil.getColumnIndexOrThrow(_cursor, "title");
          final int _cursorIndexOfRecipeDescription = CursorUtil.getColumnIndexOrThrow(_cursor, "recipeDescription");
          final int _cursorIndexOfServings = CursorUtil.getColumnIndexOrThrow(_cursor, "servings");
          final int _cursorIndexOfPrepMinutes = CursorUtil.getColumnIndexOrThrow(_cursor, "prepMinutes");
          final int _cursorIndexOfCookMinutes = CursorUtil.getColumnIndexOrThrow(_cursor, "cookMinutes");
          final int _cursorIndexOfRating = CursorUtil.getColumnIndexOrThrow(_cursor, "rating");
          final int _cursorIndexOfSource = CursorUtil.getColumnIndexOrThrow(_cursor, "source");
          final int _cursorIndexOfSourceUrl = CursorUtil.getColumnIndexOrThrow(_cursor, "sourceUrl");
          final int _cursorIndexOfCategoriesJson = CursorUtil.getColumnIndexOrThrow(_cursor, "categoriesJson");
          final int _cursorIndexOfPhotoOriginal = CursorUtil.getColumnIndexOrThrow(_cursor, "photoOriginal");
          final int _cursorIndexOfPhotoLarge1024 = CursorUtil.getColumnIndexOrThrow(_cursor, "photoLarge1024");
          final int _cursorIndexOfPhotoThumb = CursorUtil.getColumnIndexOrThrow(_cursor, "photoThumb");
          final int _cursorIndexOfUpdatedAt = CursorUtil.getColumnIndexOrThrow(_cursor, "updatedAt");
          final int _cursorIndexOfDeviceId = CursorUtil.getColumnIndexOrThrow(_cursor, "deviceId");
          final int _cursorIndexOfDeleted = CursorUtil.getColumnIndexOrThrow(_cursor, "deleted");
          final RecipeEntity _result;
          if (_cursor.moveToFirst()) {
            final String _tmpId;
            _tmpId = _cursor.getString(_cursorIndexOfId);
            final String _tmpHouseholdId;
            _tmpHouseholdId = _cursor.getString(_cursorIndexOfHouseholdId);
            final String _tmpTitle;
            _tmpTitle = _cursor.getString(_cursorIndexOfTitle);
            final String _tmpRecipeDescription;
            _tmpRecipeDescription = _cursor.getString(_cursorIndexOfRecipeDescription);
            final double _tmpServings;
            _tmpServings = _cursor.getDouble(_cursorIndexOfServings);
            final Integer _tmpPrepMinutes;
            if (_cursor.isNull(_cursorIndexOfPrepMinutes)) {
              _tmpPrepMinutes = null;
            } else {
              _tmpPrepMinutes = _cursor.getInt(_cursorIndexOfPrepMinutes);
            }
            final Integer _tmpCookMinutes;
            if (_cursor.isNull(_cursorIndexOfCookMinutes)) {
              _tmpCookMinutes = null;
            } else {
              _tmpCookMinutes = _cursor.getInt(_cursorIndexOfCookMinutes);
            }
            final Double _tmpRating;
            if (_cursor.isNull(_cursorIndexOfRating)) {
              _tmpRating = null;
            } else {
              _tmpRating = _cursor.getDouble(_cursorIndexOfRating);
            }
            final String _tmpSource;
            _tmpSource = _cursor.getString(_cursorIndexOfSource);
            final String _tmpSourceUrl;
            _tmpSourceUrl = _cursor.getString(_cursorIndexOfSourceUrl);
            final String _tmpCategoriesJson;
            _tmpCategoriesJson = _cursor.getString(_cursorIndexOfCategoriesJson);
            final String _tmpPhotoOriginal;
            if (_cursor.isNull(_cursorIndexOfPhotoOriginal)) {
              _tmpPhotoOriginal = null;
            } else {
              _tmpPhotoOriginal = _cursor.getString(_cursorIndexOfPhotoOriginal);
            }
            final String _tmpPhotoLarge1024;
            if (_cursor.isNull(_cursorIndexOfPhotoLarge1024)) {
              _tmpPhotoLarge1024 = null;
            } else {
              _tmpPhotoLarge1024 = _cursor.getString(_cursorIndexOfPhotoLarge1024);
            }
            final String _tmpPhotoThumb;
            if (_cursor.isNull(_cursorIndexOfPhotoThumb)) {
              _tmpPhotoThumb = null;
            } else {
              _tmpPhotoThumb = _cursor.getString(_cursorIndexOfPhotoThumb);
            }
            final long _tmpUpdatedAt;
            _tmpUpdatedAt = _cursor.getLong(_cursorIndexOfUpdatedAt);
            final String _tmpDeviceId;
            _tmpDeviceId = _cursor.getString(_cursorIndexOfDeviceId);
            final boolean _tmpDeleted;
            final int _tmp;
            _tmp = _cursor.getInt(_cursorIndexOfDeleted);
            _tmpDeleted = _tmp != 0;
            _result = new RecipeEntity(_tmpId,_tmpHouseholdId,_tmpTitle,_tmpRecipeDescription,_tmpServings,_tmpPrepMinutes,_tmpCookMinutes,_tmpRating,_tmpSource,_tmpSourceUrl,_tmpCategoriesJson,_tmpPhotoOriginal,_tmpPhotoLarge1024,_tmpPhotoThumb,_tmpUpdatedAt,_tmpDeviceId,_tmpDeleted);
          } else {
            _result = null;
          }
          return _result;
        } finally {
          _cursor.close();
          _statement.release();
        }
      }
    }, $completion);
  }

  @Override
  public Object count(final Continuation<? super Integer> $completion) {
    final String _sql = "SELECT COUNT(*) FROM recipes";
    final RoomSQLiteQuery _statement = RoomSQLiteQuery.acquire(_sql, 0);
    final CancellationSignal _cancellationSignal = DBUtil.createCancellationSignal();
    return CoroutinesRoom.execute(__db, false, _cancellationSignal, new Callable<Integer>() {
      @Override
      @NonNull
      public Integer call() throws Exception {
        final Cursor _cursor = DBUtil.query(__db, _statement, false, null);
        try {
          final Integer _result;
          if (_cursor.moveToFirst()) {
            final int _tmp;
            _tmp = _cursor.getInt(0);
            _result = _tmp;
          } else {
            _result = 0;
          }
          return _result;
        } finally {
          _cursor.close();
          _statement.release();
        }
      }
    }, $completion);
  }

  @NonNull
  public static List<Class<?>> getRequiredConverters() {
    return Collections.emptyList();
  }
}
